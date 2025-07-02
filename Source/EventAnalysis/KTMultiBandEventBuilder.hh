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

#include <set>
#include <vector>
#include <map>
#include <memory>

namespace Katydid
{

    /*!
     @class KTMultiBandEventBuilder
     @authors H.S. Harrington and N. Buzinsky

     @brief looks for events within tracks in the same aquisition

     @details TODO
     
     Configuration name: "multi-band-event-builder"

     Available configuration values:
     - "epsilon": double -- some distance tbd

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
            MEMBERVARIABLE(double, Epsilon);
            // Internal tracking
            MEMBERVARIABLE_PROTECTED(unsigned, NEventsEmitted);
            MEMBERVARIABLE_PROTECTED(unsigned, MinTracksInAcqToRun);
            double fTimeBinWidth = 0.0;
            double fFreqBinWidth = 0.0;

        public:
            bool ReceiveLongTrackCandidate(KTLongTrackData& trackData);
            bool BuildEvents();
            bool Run();
            void EmitEvents(const std::vector<std::vector<KTLongTrackData*>>& groupsInAcq);

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
