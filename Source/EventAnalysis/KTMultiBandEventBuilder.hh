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

     Slots:
     - "long-track-cand": void (KTDataPtr) -- If this is a new acquisition; Adds track candidates to the internally-stored set of points; guarantees KTLongTrackData
     - "build-events: void () -- Triggers clustering algorithm; Send after all track candidates have been found!

     Signals:
     - "mbe-cand": void (KTDataPtr) -- Emitted for each event found; Guarantees KTMultiBandEventData.
     - "event-builder-done": void () -- Emitted when the event builder is done with ALL aquisitions
    */


    class EventTopology
    {
        public:
            std::bitset<5> binaryID;
            unsigned decimalID;
            unsigned nBands;
            std::string label;
            std::vector<unsigned> bands;

            EventTopology(const char *aCharLabel): label(aCharLabel)
            {
                binaryID = std::bitset<5>(label);
                decimalID = binaryID.to_ulong();
                nBands = binaryID.count();

                // Reverse indexing because bitset stores from right to left
                for (int i = 0; i < 5; ++i)
                {
                    //Maps index 0->-2, 1->-1, 2->0, 3->1, 4->2
                    if (binaryID[4 - i])
                        bands.push_back(i - 2);
                }
            }

    };

    class KTMultiBandEventBuilder : public Nymph::KTProcessor
    {
        public:
            KTMultiBandEventBuilder(const std::string& name = "multi-band-event-builder");
            virtual ~KTMultiBandEventBuilder();

            bool Configure(const scarab::param_node* node);
            MEMBERVARIABLE(double, ExpectedTracksPerAcq);
            MEMBERVARIABLE(std::vector<double>, TrackFrequencyBandwidths);
            MEMBERVARIABLE(std::vector<double>, LogPoisson);
            // Internal tracking
            MEMBERVARIABLE_PROTECTED(unsigned, NEventsEmitted);
            MEMBERVARIABLE_PROTECTED(unsigned, MinTracksInAcqToRun);
            MEMBERVARIABLE_PROTECTED(unsigned, MaxTracksInAcqToRun);
            double fTimeBinWidth = 0.0;
            double fFreqBinWidth = 0.0;

        public:
            bool ReceiveLongTrackCandidate(KTLongTrackData& trackData);
            bool BuildEvents();
            bool Run();
            void EmitEvents(const std::vector<std::vector<KTLongTrackData*>>& groupsInAcq);
            std::vector<partition> GetAllPartitions(const int &nTracks);
            void RecursivePartitionGenerator(const int &nTracks, unsigned short current, const partition& current_partition, std::vector<partition>& result);

        private:
            /// Map of AcqID -> vector of tracks
            std::map<unsigned, std::vector<KTLongTrackData*>> fTracksPerAcq;
            std::vector<std::vector<KTLongTrackData*>> FindGroupsInAcq(const std::vector<KTLongTrackData*>& tracks);
            std::vector<EventTopology> fEventTopologies;


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
