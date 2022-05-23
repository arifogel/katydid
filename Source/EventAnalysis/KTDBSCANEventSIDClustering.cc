/*
 * KTDBSCANEventSIDClustering.cc
 *
 *  Created on: Aug 4, 2014
 *      Author: N.S. Oblath
 */

#include "KTDBSCANEventSIDClustering.hh"
#include "KTLogger.hh"
#include "KTMath.hh"
#include "KTMultiTrackEventData.hh"
#include "KTProcessedTrackData.hh"

#ifndef NDEBUG
#include <sstream>
#endif

using std::set;
using std::vector;

namespace Katydid
{
    KTLOGGER(tclog, "katydid.fft");

    KT_REGISTER_PROCESSOR(KTDBSCANEventSIDClustering, "dbscan-event-SID-clustering");

    // dimensions: (t_start, f_start, t_end, f_end, f_slope, f_xint)
    const unsigned KTDBSCANEventSIDClustering::fNDimensions = 6;
    const unsigned KTDBSCANEventSIDClustering::fRadiiSize = 4;
    // points in a track: (start, end)
    const unsigned KTDBSCANEventSIDClustering::fNPointsPerTrack = 2;

    KTDBSCANEventSIDClustering::KTDBSCANEventSIDClustering(const std::string& name) :
            KTPrimaryProcessor(name),
            fRadii(fRadiiSize),
            fMinPoints(3),
            fTimeBinWidth(1),
            fFreqBinWidth(1.),
            fCompTracks(1, vector< KTProcessedTrackData >()),
            fCandidates(),
            fDataCount(0),
            fEventSignal("event", this),
            fClusterDoneSignal("clustering-done", this),
            fTakeTrackSlot("track", this, &KTDBSCANEventSIDClustering::TakeTrack)
    //        fDoClusterSlot("do-cluster-trigger", this, &KTDBSCANEventSIDClustering::Run)
    {
        RegisterSlot("do-clustering", this, &KTDBSCANEventSIDClustering::DoClusteringSlot);
        fRadii(0) = 1. / sqrt(fNDimensions);
        fRadii(1) = 1. / sqrt(fNDimensions);
        fRadii(2) = 1. / sqrt(fNDimensions);
        fRadii(3) = 1. / sqrt(fNDimensions);
    }

    KTDBSCANEventSIDClustering::~KTDBSCANEventSIDClustering()
    {
    }

    bool KTDBSCANEventSIDClustering::Configure(const scarab::param_node* node)
    {
        if (node == NULL) return false;

        SetMinPoints(node->get_value("min-points", GetMinPoints()));

        if (node->has("radii"))
        {
            const scarab::param_array* radii = node->array_at("radii");
            if (radii->size() != fRadiiSize)
            {
                KTERROR(tclog, "Radii array does not have the right number of dimensions: <" << radii->size() << "> instead of <" << fRadiiSize << ">");
                return false;
            }
            fRadii(0) = radii->get_value< double >(0);
            fRadii(1) = radii->get_value< double >(1);
            fRadii(2) = radii->get_value< double >(2);
            fRadii(3) = radii->get_value< double >(3);
        }

        return true;
    }

    bool KTDBSCANEventSIDClustering::TakeTrack(KTProcessedTrackData& track)
    {
        // ignore the track if it's been cut
        if (track.GetIsCut()) return true;

        // verify that we have the right number of components
        if (track.GetComponent() >= fCompTracks.size())
        {
            SetNComponents(track.GetComponent() + 1);
        }

        // copy the full track data
        fCompTracks[track.GetComponent()].push_back(track);

        KTDEBUG(tclog, "Taking track: (" << track.GetStartTimeInRunC() << ", " << track.GetStartFrequency() << ", " << track.GetEndTimeInRunC() << ", " << track.GetEndFrequency() << ", " << track.GetSlope());

        return true;
    }

    void KTDBSCANEventSIDClustering::DoClusteringSlot()
    {
        if (! Run())
        {
            KTERROR(tclog, "An error occurred while running the event clustering");
        }
        return;
    }

    bool KTDBSCANEventSIDClustering::Run()
    {
        return DoClustering();
    }

    bool KTDBSCANEventSIDClustering::DoClustering()
    {
        KTPROG(tclog, "Starting DBSCAN event clustering");

        KTDBSCAN< DistanceMatrix > dbScan;

        dbScan.SetRadius(1.);
        dbScan.SetMinPoints(fMinPoints);
        KTINFO(tclog, "DBSCAN configured");

        for (unsigned iComponent = 0; iComponent < fCompTracks.size(); ++iComponent)
        {
            KTDEBUG(tclog, "Clustering component " << iComponent);

            if (fCompTracks[iComponent].empty() )
                continue;

            // calculate the scaling
            Point scale = fRadii;
            scale(0) = 1. / (scale(0) * KTMath::Sqrt2());
            scale(1) = 1. / (scale(1) * KTMath::Sqrt2());
            scale(2) = 1. / scale(2);
            scale(3) = 1. / scale(3);

            // new array for normalized points
            Points normPoints(fCompTracks[iComponent].size());
            Point newPoint(fNDimensions);
            // normalize points
            KTDEBUG(tclog, "Scale: " << scale);
            unsigned iPoint = 0;
            for (vector< KTProcessedTrackData >::const_iterator pIt = fCompTracks[iComponent].begin(); pIt != fCompTracks[iComponent].end(); ++pIt)
            {
                //std::cerr << "1" << std::endl;
                newPoint(0) = pIt->GetStartTimeInRunC() * scale(0); // start time
                //std::cerr << "2" << std::endl;
                newPoint(1) = pIt->GetStartFrequency() * scale(1);  // start freq
                //std::cerr << "3" << std::endl;
                newPoint(2) = pIt->GetEndTimeInRunC() * scale(0);   // end time
                //std::cerr << "4" << std::endl;
                newPoint(3) = pIt->GetEndFrequency() * scale(1);    // end freq
                //std::cerr << "5" << std::endl;
                newPoint(4) = pIt->GetSlope()  * scale(2);    // track slope

                double scaledSlope = (newPoint(3)-newPoint(1))/(newPoint(2)-newPoint(0)); //Scaled change in frequency over change in time for this track

                newPoint(5) = newPoint(0) - (newPoint(1)/scaledSlope) * scale(3);    // x_int

#ifndef NDEBUG
                std::stringstream ptStr;
                //ptStr << "Point -- before: (" << newPoint(0) << ", " << newPoint(1) << ", " << newPoint(2) << ", " << newPoint(3) <<  "," << newPoint(4) <<  "," << newPoint(5) << ")";
#endif
                KTDEBUG(tclog, ptStr.str() << " -- after: " << newPoint);
                normPoints[iPoint++] = newPoint;
            }

            DistanceMatrix distMat;
            distMat.ComputeDistances< TrackDistance< Point > >(normPoints);

            // do the clustering!
            KTINFO(tclog, "Starting DBSCAN");
            KTDBSCAN< DistanceMatrix >::DBSResults results;
            if (! dbScan.DoClustering(distMat, results))
            {
                KTERROR(tclog, "An error occurred while clustering");
                return false;
            }
            KTDEBUG(tclog, "DBSCAN finished");

            // loop over the clusters found, and create data objects for them
            KTDEBUG(tclog, "Found " << results.fClusters.size() << " clusters; creating candidate events");
            for (vector< KTDBSCAN< DistanceMatrix >::Cluster >::const_iterator clustIt = results.fClusters.begin(); clustIt != results.fClusters.end(); ++clustIt)
            {
                if (clustIt->empty())
                {
                    KTWARN(tclog, "Empty cluster");
                    continue;
                }

                KTDEBUG(tclog, "Creating event " << fDataCount << "; includes " << clustIt->size() << " tracks");

                ++fDataCount;

                Nymph::KTDataPtr data(new Nymph::KTData());

                KTMultiTrackEventData& eventData = data->Of< KTMultiTrackEventData >();
                eventData.SetComponent(iComponent);
                eventData.SetAcquisitionID(fCompTracks[0][0].GetAcquisitionID());
                eventData.SetEventID(fDataCount);

                for (KTDBSCAN< DistanceMatrix >::Cluster::const_iterator pointIdIt = clustIt->begin(); pointIdIt != clustIt->end(); ++pointIdIt)
                {
                    double la = fCompTracks[iComponent][*pointIdIt].GetStartTimeInRunC() * scale(0); // scaled start time
                    double lb = fCompTracks[iComponent][*pointIdIt].GetStartFrequency() * scale(1);  // scaled start freq
                    double lc = fCompTracks[iComponent][*pointIdIt].GetEndTimeInRunC() * scale(0);   // scaled end time
                    double ld = fCompTracks[iComponent][*pointIdIt].GetEndFrequency() * scale(1);    // scaled end freq
                    double le = fCompTracks[iComponent][*pointIdIt].GetSlope()  * scale(2);    // scaled track slope

                    double scaledSlope = (ld-lb)/(lc-la); //Scaled change in frequency over change in time for this track

                    double lf = la - (lb/scaledSlope) * scale(3);    // scaled x_int

                    KTDEBUG(tclog, "Adding track with:" << la << ", "<< lb << ", "<< lc << ", "<<ld << ", "<<le << ", "<<lf);
                    eventData.AddTrack(fCompTracks[iComponent][*pointIdIt]);
                }

                eventData.ProcessTracks();

                fCandidates.insert(data);
                fEventSignal(data);
            } // loop over clusters

            fCompTracks[iComponent].clear();

        } // loop over components

        KTDEBUG(tclog, "Clustering complete");
        fClusterDoneSignal();

        return true;
    }

    void KTDBSCANEventSIDClustering::SetNComponents(unsigned nComps)
    {
        fCompTracks.resize(nComps, vector< KTProcessedTrackData >());
        return;
    }

} /* namespace Katydid */
