/**
 @file KTDBSCANEventSIDClustering.hh
 @brief Contains KTDBSCANEventSIDClustering
 @details Clusters tracks into events
 @author: N.S. Oblath
 @date: Aug 4, 2014
 */

#ifndef KTDBSCANEVENTSIDCLUSTERING_HH_
#define KTDBSCANEVENTSIDCLUSTERING_HH_

#include "KTPrimaryProcessor.hh"

#include "KTDBSCAN.hh"
#include "KTDistanceMatrix.hh"
#include "KTSlot.hh"
#include "KTData.hh"
#include "KTMemberVariable.hh"

#include <algorithm>
#include <set>
#include <vector>


namespace Katydid
{
    
    class KTProcessedTrackData;

    // Track distance
    // Vector format for representing tracks: (tstart, fstart, tend, fend, slope, x_intScale)
    // Dimension t: for tstart_1 < tstart_2, Dt = max(0, tstart_2 - tend_1)
    // Dimension f: Df = fstart_2 - fend_1
    // Dist = sqrt(Dt^2 + Df^2)
    template < typename VEC_T >
    class TrackDistance
    {
        protected:
            typedef VEC_T vector_type;

            double GetDistance(const VEC_T v1, const VEC_T v2)
            {
                double deltaT, deltaF;
                double deltaS, deltaI, deltaD;

                if (v1(0) < v2(0))
                {
                    deltaT = std::max(0., v2(0) - v1(2));
                    deltaF = v2(1) - v1(3);
                }
                else
                {
                    deltaT = std::max(0., v1(0) - v2(2));
                    deltaF = v1(1) - v2(3);
                }

                //Definition of Distance between two tracks in frequency-time space
                deltaD = sqrt(deltaT * deltaT + deltaF * deltaF);
                //Difference between their Slopes
                deltaS = v2(4)-v1(4);
                //Difference between their x_Intercepts
                deltaI =  v2(5)-v1(5);

                //Combine distances in Slope, xIntercept, and f-t Distance to define how far the tracks are from eachother in SID space
                return sqrt(deltaS * deltaS + deltaI * deltaI + deltaD * deltaD);
            };

    };


    /*!
     @class KTDBSCANEventSIDClustering
     @author N.S. Oblath

     @brief Clustering for finding events using the DBSCAN algorithm

     @details
     Normalization of the axes:
     The DBSCAN algorithm expects expects that all of the dimensions that describe a points will have the same scale,
     such that a single radius parameter can describe a sphere in the parameter space that's used to cluster points together.
     For track clustering, two radii are specified, one for the time dimension and one for the frequency dimension.
     For clustering, a scaling factor is calculated for each axis such that the ellipse formed by the two radii is
     scaled to a unit circle.  Those scaling factors are applied to every point before the data is passed to the
     DBSCAN algorithm.

     Configuration name: "dbscan-event-clustering"

     Available configuration values:
     - "radii": double[2] -- array used to describe the distances that will be used to cluster tracks together; [time, frequency]
     - "min-points": unsigned int -- minimum number of tracks required to have a cluster

     Slots:
     - "track": void (shared_ptr<KTData>) -- If this is a new acquisition; Adds tracks to the internally-stored set of points; Requires KTSliceHeader and KTDiscriminatedPoints1DData.
     - "do-clustering": void () -- Triggers clustering algorithm

     Signals:
     - "event": void (shared_ptr<KTData>) -- Emitted for each cluster found; Guarantees KT???Data.
     - "clustering-done": void () -- Emitted when track clustering is complete
    */

    class KTDBSCANEventSIDClustering : public Nymph::KTPrimaryProcessor
    {
        public:
            typedef KTSymmetricDistanceMatrix< double > DistanceMatrix;
            typedef DistanceMatrix::Point Point;
            typedef DistanceMatrix::Points Points;

            const static unsigned fNDimensions;
            const static unsigned fNPointsPerTrack;
            const static unsigned fRadiiSize;

        public:
            KTDBSCANEventSIDClustering(const std::string& name = "dbscan-event-clustering");
            virtual ~KTDBSCANEventSIDClustering();

            bool Configure(const scarab::param_node* node);

            MEMBERVARIABLE(unsigned, MinPoints);
            MEMBERVARIABLEREF(Point, Radii);

        public:
            // Store point information locally
            bool TakeTrack(KTProcessedTrackData& track);
            //bool TakeTrack(double startTime, double startFreq, double endTime, double endFreq, unsigned component=0);

            void SetNComponents(unsigned nComps);
            void SetTimeBinWidth(double bw);
            void SetFreqBinWidth(double bw);

            bool Run();

            bool DoClustering();

            const std::set< Nymph::KTDataPtr >& GetCandidates() const;
            unsigned GetDataCount() const;

        private:

            double fTimeBinWidth;
            double fFreqBinWidth;

            std::vector< std::vector< KTProcessedTrackData > > fCompTracks; // input tracks

            std::set< Nymph::KTDataPtr > fCandidates;
            unsigned fDataCount;

            //***************
            // Signals
            //***************

        private:
            Nymph::KTSignalData fEventSignal;
            Nymph::KTSignalOneArg< void > fClusterDoneSignal;

            //***************
            // Slots
            //***************

        private:
            Nymph::KTSlotDataOneType< KTProcessedTrackData > fTakeTrackSlot;
            //Nymph::KTSlotDataOneType< KTInternalSignalWrapper > fDoClusterSlot;

            void DoClusteringSlot();

    };

    inline void KTDBSCANEventSIDClustering::SetTimeBinWidth(double bw)
    {
        fTimeBinWidth = bw;
        return;
    }
    inline void KTDBSCANEventSIDClustering::SetFreqBinWidth(double bw)
    {
        fFreqBinWidth = bw;
        return;
    }

    inline const std::set< Nymph::KTDataPtr >& KTDBSCANEventSIDClustering::GetCandidates() const
    {
        return fCandidates;
    }
    inline unsigned KTDBSCANEventSIDClustering::GetDataCount() const
    {
        return fDataCount;
    }


}
 /* namespace Katydid */
#endif /* KTDBSCANEventSIDClustering_HH_ */
