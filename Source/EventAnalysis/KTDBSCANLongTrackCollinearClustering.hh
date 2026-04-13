/**
 @file KTDBSCANLongTrackCollinearClustering.hh
 @brief Contains KTDBSCANLongTrackCollinearClustering
 @details clusters tracks based on their AcqFreqIntercept (frequency-intercept definded at the start of the aquisition) using a DBScan clustering algorythm.
 For use in combining collinear track segments!
 Currently only implemented for KTLongTrackData
 @author: H.S. Harrington
 @date: June 10 2025
 */

#ifndef KTDBSCANLONGTRACKCOLLINEARCLUSTERING_HH_
#define KTDBSCANLONGTRACKCOLLINEARCLUSTERING_HH_ 

#include "KTProcessor.hh"

#include "KTDBSCAN.hh"
#include "KTDistanceMatrix.hh"
#include "KTMemberVariable.hh"
#include "KTSlot.hh"
#include "KTData.hh"

#include <set>
#include <vector>


namespace Katydid
{

    class KTLongTrackData;

    /*!
     @class KTDBSCANLongTrackCollinearClustering
     @author H.S. Harrington

     @brief Clustering collinear tracks using the DBSCAN algorithm

     @details
     We are clustering on just one dimension (track freq intercept at acq. start), so epsilon is a 1d clustering distance.
     For clustering, a scaling factor is calculated so that the clustering distance in unity for the actual DBScan algorithm.

     Configuration name: "dbscan-track-collinear-clustering"

     Available configuration values:
     - "freq-int-epsilon": double -- distance between two points to be clustered together
     - "empty-start-time": double -- time in cycle that trap starts emptying

     Slots:
     - "long-track-cand": void (KTDataPtr) -- If this is a new acquisition; Adds track candidates to the internally-stored set of points; guarantees KTLongTrackData
     - "do-clustering": void () -- Triggers clustering algorithm; Send after all track candidates have been found!

     Signals:
     - "clust-long-track-cand": void (shared_ptr<KTData>) -- Emitted for each cluster found; Guarantees KTLongTrackData.
     - "clustering-done": void () -- Emitted when track clustering is complete
    */

    class KTDBSCANLongTrackCollinearClustering : public Nymph::KTProcessor
    {
        public:
            typedef KTSymmetricDistanceMatrix< double > DistanceMatrix;
            typedef DistanceMatrix::Point FeatureValue;
            typedef DistanceMatrix::Points FeatureValues;

        public:
            KTDBSCANLongTrackCollinearClustering(const std::string& name = "dbscan-longtrack-collinear-clustering");
            virtual ~KTDBSCANLongTrackCollinearClustering();

            bool Configure(const scarab::param_node* node);
            MEMBERVARIABLE(double, Epsilon);  // 1D clustering, so scalar
            MEMBERVARIABLE(double, EmptyStartTime);
            // Internal tracking
            MEMBERVARIABLE_PROTECTED(unsigned, NCandidatesEmitted);
            MEMBERVARIABLE_PROTECTED(unsigned, MinTracksInAcqToRun);
            MEMBERVARIABLE_PROTECTED(unsigned, MinTracksInClust);
            double fTimeBinWidth = 0.0;
            double fFreqBinWidth = 0.0;

        public:
            bool ReceiveLongTrackCandidate(KTLongTrackData& trackData);
            bool DoClustering();
            bool Run();
            void EmitCombinedTrack(std::vector<KTLongTrackData*>& clusterTracks);
            const std::set< Nymph::KTDataPtr >& GetCandidates() const;

        private:
            std::set< Nymph::KTDataPtr > fCandidates;
            std::map<unsigned, std::vector<KTLongTrackData*> > fTracksPerAcq;

            //***************
            // Signals
            //***************

        private:
            Nymph::KTSignalData fNewTrackSignal;
            Nymph::KTSignalOneArg< void > fClusterDoneSignal;

            //***************
            // Slots
            //***************

        private:
            Nymph::KTSlotDataOneType< KTLongTrackData > fInputTrackSlot;
            void DoClusteringSlot();
    };

    inline const std::set< Nymph::KTDataPtr >& KTDBSCANLongTrackCollinearClustering::GetCandidates() const
    {
        return fCandidates;
    }


}
 /* namespace Katydid */
#endif /* KTDBSCANLONGTRACKCOLLINEARCLUSTERING_HH_ */
