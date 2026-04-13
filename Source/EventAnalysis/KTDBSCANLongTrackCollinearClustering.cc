/*
 * KTDBSCANLongTrackCollinearClustering.cc
 *
 *  Created on: June 10 2025
 *      Author: H.S. Harrington
 */
#include "KTDBSCANLongTrackCollinearClustering.hh"
#include "KTLogger.hh"
#include "KTDBSCAN.hh"
#include "KTLongTrackData.hh"

#include <cmath>
#include <numeric>
#include <algorithm>
using std::set;
using std::vector;

namespace Katydid
{
    KTLOGGER(tclog, "katydid.fft");
    KT_REGISTER_PROCESSOR(KTDBSCANLongTrackCollinearClustering, "dbscan-longtrack-collinear-clustering");

    KTDBSCANLongTrackCollinearClustering::KTDBSCANLongTrackCollinearClustering(const std::string& name) :
        KTProcessor(name),
        fEpsilon(0.5),
        fEmptyStartTime(0.0018364),
        fMinTracksInAcqToRun(1),
        fMinTracksInClust(1),
        fTracksPerAcq(),
        fNCandidatesEmitted(0),
        fCandidates(),
        fNewTrackSignal("clust-long-track-cand", this),
        fClusterDoneSignal("clustering-done", this),
        fInputTrackSlot("long-track-cand", this, &KTDBSCANLongTrackCollinearClustering::ReceiveLongTrackCandidate)
    {
        RegisterSlot("do-clustering", this, &KTDBSCANLongTrackCollinearClustering::DoClusteringSlot);
    }


    KTDBSCANLongTrackCollinearClustering::~KTDBSCANLongTrackCollinearClustering()
    {
        // Clean up dynamically allocated tracks
        for (auto& entry : fTracksPerAcq)
        {
            auto& tracks = entry.second;
            for (auto* track : tracks)
            {
                delete track;
            }
        }
    }
    void KTDBSCANLongTrackCollinearClustering::DoClusteringSlot()
    {
        if (! Run())
        {
            KTERROR(tclog, "An error occurred while running the collinear track clustering");
        }
        return;
    }

    bool KTDBSCANLongTrackCollinearClustering::Run()
    {
        return DoClustering();
    }
    bool KTDBSCANLongTrackCollinearClustering::Configure(const scarab::param_node* node)
    {
        if (node == NULL) return false;
        SetEpsilon(node->get_value("freq-int-epsilon", GetEpsilon()));
        SetEmptyStartTime(node->get_value("empty-start-time", GetEmptyStartTime()));
        return true;
    }

    bool KTDBSCANLongTrackCollinearClustering::ReceiveLongTrackCandidate(KTLongTrackData& trackData)
    {
        const auto& stats = trackData.GetTrackStats();
        KTDEBUG(tclog, "Received track with AcqID " << stats.StartAcqID 
            << ", freq intercept = " << stats.AcqFreqIntercept);
        
        // Set global bin widths if this is the first track ever
        if (fTimeBinWidth == 0.0 && fFreqBinWidth == 0.0)
        {
            fTimeBinWidth = stats.TimeBinWidth;
            fFreqBinWidth = stats.FreqBinWidth;
            KTINFO(tclog, "Initialized global bin widths: time = " << fTimeBinWidth << ", freq = " << fFreqBinWidth);
        }

        // Store a copy (allocate on heap for now)
        fTracksPerAcq[stats.StartAcqID].push_back(new KTLongTrackData(trackData));
        return true;
    }

bool KTDBSCANLongTrackCollinearClustering::DoClustering()
{
    KTINFO(tclog, "Running frequency intercept clustering on all stored track candidates. "
                  "Will only cluster those with same AcqID!");

    for (auto& entry : fTracksPerAcq) // for each acquisition
    {
        unsigned acqID = entry.first;
        auto& allTracks = entry.second;

        if (allTracks.size() < fMinTracksInAcqToRun)
        {
            KTDEBUG(tclog, "Skipping AcqID " << acqID
                     << ": has < (" << allTracks.size() << ") track candidates.");
            continue;
        }

        // Separate tracks into two groups: clusterable vs immediate emit
        std::vector<KTLongTrackData*> clusterable;
        FeatureValues featureValues;

        for (auto* track : allTracks)
        {
            if (track->GetTrackStats().StartTimeInAcqC < fEmptyStartTime)
            {
                clusterable.push_back(track);
                FeatureValue pt(1);
                pt(0) = track->GetTrackStats().AcqFreqIntercept;
                featureValues.push_back(pt);
            }
            else
            {
                std::vector<KTLongTrackData*> singleton{track};
                EmitCombinedTrack(singleton);
            }
        }

        // Build DBSCAN distance matrix
        KTDBSCAN<DistanceMatrix> dbScan;
        dbScan.SetRadius(fEpsilon);
        dbScan.SetMinPoints(fMinTracksInClust);

        DistanceMatrix distMat;
        distMat.ComputeDistances<Euclidean<FeatureValue>>(featureValues);

        KTDBSCAN<DistanceMatrix>::DBSResults results;
        if (!dbScan.DoClustering(distMat, results))
        {
            KTERROR(tclog, "DBSCAN failed for AcqID " << acqID);
            continue;
        }

        // Emit results
        for (size_t clusterID = 0; clusterID < results.fClusters.size(); ++clusterID)
        {
            const auto& cluster = results.fClusters[clusterID];
            std::vector<KTLongTrackData*> clusterTracks;
            for (size_t pointID : cluster)
            {
                clusterTracks.push_back(clusterable[pointID]);
            }
            EmitCombinedTrack(clusterTracks);
        }

        for (size_t i = 0; i < results.fNoise.size(); ++i)
        {
            if (results.fNoise[i])
            {
                std::vector<KTLongTrackData*> singleton = { clusterable[i] };
                EmitCombinedTrack(singleton);
            }
        }

        // cleanup
        for (auto* track : allTracks) delete track;
        allTracks.clear();
    }

    fTracksPerAcq.clear();
    fClusterDoneSignal();
    return true;
}

    void KTDBSCANLongTrackCollinearClustering::EmitCombinedTrack(std::vector<KTLongTrackData*>& clusterTracks)
    {
        // Set up new data object
        Nymph::KTDataPtr data(new Nymph::KTData());
        auto& newCand = data->Of<KTLongTrackData>();
        newCand.SetTrackId(fNCandidatesEmitted);
        newCand.SetEventId(fNCandidatesEmitted); //Set the eventID to the trackID for now, can be re-assigned by a later event-builder
        newCand.SetBandNumber(0); //All set to 0 (main band) for now, can be re-assigned by a later event-builder

        //Adding all points from clustered tracks into a new canidate track
        size_t totalPoints = 0;
        for (auto* track : clusterTracks)
        {
            const auto& points = track->GetPoints();
            totalPoints += points.size();

            for (const auto& pt : points)
            {
                newCand.AddPoint(pt);  // this is KTLongTrackData::Point
            }
        }
        // Sort points by time and frequency using existing SetPoints() logic
        newCand.SetPoints(newCand.GetPoints());
        KTDEBUG(tclog, "Combined " << clusterTracks.size() << " tracks with " << totalPoints << " total points");

        // Compute and store track stats
        newCand.CalculateTrackStats(fTimeBinWidth,fFreqBinWidth);

        fNCandidatesEmitted++;
        fCandidates.insert(data);
        fNewTrackSignal(data);
    }

 }/* namespace Katydid */