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
        fMinTracksInAcqToRun(2),
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
            KTERROR(tclog, "An error occurred while running the event clustering");
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
        return true;
    }

    bool KTDBSCANLongTrackCollinearClustering::ReceiveLongTrackCandidate(KTLongTrackData& trackData)
    {
        const auto& stats = trackData.GetTrackStats();
        KTDEBUG(tclog, "Received track with AcqID " << stats.StartAcqID << ", freq intercept = " << stats.AcqFreqIntercept );
        
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
        KTINFO(tclog, "Running frequency intercept clustering on all stored track candidates. Will only cluster those with same AcqID!" );

        for (auto& entry : fTracksPerAcq)
        {
            unsigned acqID = entry.first;
            auto& tracks = entry.second;
            // tracks.size() will return the number of tracks that were stored with that particular StartAcqID
            if (tracks.size() < fMinTracksInAcqToRun)
            {
                KTDEBUG( tclog, "Skipping AcqID " << acqID << ": has < (" << tracks.size() << ") track candidates." );
                continue;
            }

            FeatureValues featureValues;
            for (const auto* track : tracks)
            {
                FeatureValue pt(1);
                pt(0) = track->GetTrackStats().AcqFreqIntercept;  // single-dimension
                featureValues.push_back(pt);
            }

            // Build a matrix of distances between arbitrary-dimensional feature vectors and supports fast radius-based neighborhood queries
            KTDBSCAN< DistanceMatrix > dbScan;
            dbScan.SetRadius(fEpsilon);
            dbScan.SetMinPoints(fMinTracksInClust);
            KTINFO(tclog, "DBSCAN configured");
            DistanceMatrix distMat;
            distMat.ComputeDistances< Euclidean<FeatureValue> >(featureValues);

            // do the clustering!
            KTINFO(tclog, "Starting DBSCAN");
            KTDBSCAN< DistanceMatrix >::DBSResults results;
            if (! dbScan.DoClustering(distMat, results))
            {
                KTERROR(tclog, "DBSCAN failed for AcqID " << acqID);
                continue;
            }

            KTDEBUG(tclog, "DBSCAN finished");
            KTDEBUG(tclog, "Total clusters: " << results.fClusters.size());
            KTDEBUG(tclog, "Noise points: " << std::count(results.fNoise.begin(), results.fNoise.end(), true))
            for (size_t clusterID = 0; clusterID < results.fClusters.size(); ++clusterID)
            {
                const auto& cluster = results.fClusters[clusterID];
                std::vector<KTLongTrackData*> clusterTracks;

                for (size_t pointID : cluster)  // pointID is an index into tracks[]
                {
                    clusterTracks.push_back(tracks[pointID]);
                }

                KTDEBUG(tclog, "Emitting combined track from cluster ID " << clusterID
                                   << " with " << cluster.size() << " original tracks");

                EmitCombinedTrack(clusterTracks);
            }
            for (size_t i = 0; i < results.fNoise.size(); ++i)
            {
                if (results.fNoise[i])
                {
                    KTDEBUG(tclog, "Track " << i << " not clustered with any other tracks; emitting as singleton cluster");
                    std::vector<KTLongTrackData*> singleton = { tracks[i] };
                    EmitCombinedTrack(singleton);
                }
            }

            for (auto* track : tracks) delete track;
            tracks.clear();  // optional, since map is cleared later anyway
        }

        fTracksPerAcq.clear();

        // Emit the signal to indicate clustering is finished
        fClusterDoneSignal();
        return true;
    }

    void KTDBSCANLongTrackCollinearClustering::EmitCombinedTrack(std::vector<KTLongTrackData*>& clusterTracks)
    {
        // Set up new data object
        Nymph::KTDataPtr data(new Nymph::KTData());
        auto& newCand = data->Of<KTLongTrackData>();
        newCand.TrackId = fNCandidatesEmitted;

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