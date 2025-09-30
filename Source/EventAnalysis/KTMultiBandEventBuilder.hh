/**
 @file KTMultiBandEventBuilder.hh
 @brief Contains MultiBandEventBuilder
 @details looks for events within tracks in the same aquisition
 Currently only implemented for KTLongTrackData
 @author: H.S. Harrington and N. Buzinsky
 @date: June 30 2025
 */

#ifndef KTMULTIBANDEVENTBUILDER_HH_
#define KTMULTIBANDEVENTBUILDER_HH_

#include "KTProcessor.hh"

#include "KTMemberVariable.hh"
#include "KTSlot.hh"
#include "KTData.hh"
#include "KTMultiBandEventData.hh"
#include "KTLongTrackData.hh"

#include <bitset>
#include <map>
#include <memory>
#include <vector>

using partition = std::vector<std::vector<unsigned short>>;

namespace Katydid
{

    /*!
     @class KTMultiBandEventBuilder
     @authors H.S. Harrington and N. Buzinsky

     @brief looks for events within tracks in the same acquisition

     @details
     Configuration name: "multi-band-event-builder"

     Available configuration values:
     - "expected-tracks-per-acq": double -- prior expectation on the number of reconstructed bands per trap acq.
     - "set-field": double -- Approx set field used to distinguish between band topologies with the same number of reconstructed tracks.

     Slots:
     - "long-track-cand": void (KTDataPtr) -- If this is a new acquisition; Adds track candidates to the internally-stored set of points; guarantees KTLongTrackData
     - "build-events: void () -- Triggers clustering algorithm; Send after all track candidates have been found!

     Signals:
     - "mbe-cand": void (KTDataPtr) -- Emitted for each event found; Guarantees KTMultiBandEventData.
     - "event-builder-done": void () -- Emitted when the event builder is done with ALL aquisitions
    */

    class KTMultiBandEventBuilder : public Nymph::KTProcessor
    {
        public:
            KTMultiBandEventBuilder(const std::string& name = "multi-band-event-builder");
            virtual ~KTMultiBandEventBuilder();

            bool Configure(const scarab::param_node* node);
            MEMBERVARIABLE(double, ExpectedTracksPerAcq);
            MEMBERVARIABLE(double, SetField);
            MEMBERVARIABLE(std::vector<std::vector<int>>, BandLabels);
            MEMBERVARIABLE(std::vector<double>, TrackFrequencyBandwidths);
            MEMBERVARIABLE(std::vector<double>, LogPoisson);
            MEMBERVARIABLE(std::vector<double>, LogEventSizePrior);
            MEMBERVARIABLE(std::vector<double>, LogTrackFrequencyBandwidths);
            // Internal tracking
            MEMBERVARIABLE_PROTECTED(unsigned, NEventsEmitted);
            MEMBERVARIABLE_PROTECTED(unsigned, MinTracksInAcqToRun);
            MEMBERVARIABLE_PROTECTED(unsigned, MaxTracksInAcqToRun);
            double fTimeBinWidth = 0.0;
            double fFreqBinWidth = 0.0;
            double fEmptyTime = 0.0;

        public:
            bool ReceiveLongTrackCandidate(KTLongTrackData& trackData);
            bool BuildEvents();
            bool Run();
            void EmitEvents(const std::vector<std::vector<KTLongTrackData*>>& groupsInAcq);
            std::vector<partition> GetAllPartitions(const int &nTracks);
            void RecursivePartitionGenerator(const int &nTracks, unsigned short current, const partition& current_partition, std::vector<partition>& result);
            bool CheckEventGoodness(const std::vector<KTLongTrackData*>& allTracks, const std::vector<unsigned short>& inds);
            std::pair<unsigned, double> LLHDataGivenEvent(const std::vector<KTLongTrackData*>& allTracks, const std::vector<unsigned short>& inds);
            std::vector<unsigned> GetMaxLIndices(const std::vector<double>& logLikelihoods, const double &tolerance);
            std::pair<unsigned, double> LLHDataGivenEvent(const std::vector<KTLongTrackData*>& tracks);

        private:
            /// Map of AcqID -> vector of tracks
            std::map<unsigned, std::vector<KTLongTrackData*>> fTracksPerAcq;
            std::vector<std::vector<KTLongTrackData*>> FindGroupsInAcq(const std::vector<KTLongTrackData*>& tracks);

        private:
            //***************
            // Signals
            //***************
            Nymph::KTSignalData fMBESignal;
            Nymph::KTSignalOneArg< void > fEventBuilderDoneSignal;

            //***************
            // Slots
            //***************
            Nymph::KTSlotDataOneType< KTLongTrackData > fInputTrackSlot;
            void BuildEventsSlot();
    };



}
 /* namespace Katydid */
#endif /* KTMULTIBANDEVENTBUILDER_HH_ */
