/*
 * KTRFSlewtoVec.hh
 *
 *  Created on: May 1, 2023
 *      Author: Heather Harrington
 */

#ifndef KTRFSLEWTOVEC_HH_
#define KTRFSLEWTOVEC_HH_

#include "KTProcessor.hh"
#include "KTData.hh"

#include "KTSlot.hh"

namespace Katydid
{
    
    KTLOGGER(avlog_hh, "KTRFSlewtoVec.hh");

    class KTSliceHeader;
    class KTPowerSpectrumData;

    /*
     @class KTRFSlewtoVec
     @author Heather Harrington

     @brief Makes a vector of slew start and end times
     NOT YET: Adds acquisition data to header based of RF signal indicating trap status

     Configuration name: "rf-slew-to-vec"

     Available configuration values:
     - "output-file"

     Slots:
     - "header": void (KTDataPtr) -- Checks if the trap changed states durring this slice and if so, writes time to vector; Requires KTSliceHeader; Adds std::vector; Emits signal "slew-times"
     - "done": void () --  Recived when spec procesor is finished.

     Signals:
     - NO "slew-vec": std::vector () -- Emitted upon scanning all headers for trap slew; Guarantees std::vector.
    */

    class KTRFSlewtoVec : public Nymph::KTProcessor
    {
        public:
            KTRFSlewtoVec(const std::string& name = "rf-slew-to-vec");
            virtual ~KTRFSlewtoVec();

            bool Configure(const scarab::param_node* node);

            MEMBERVARIABLE(std::string, Filename);


        private:
            std::vector< double > fSlewStartEndTimes;
            std::vector< double > fPriorSlices;
            int fPriorMean;

        public:
            bool GetOnOffTimes(KTSliceHeader& slHeader, KTPowerSpectrumData& spectrum);
            void RunIsOver();

        //***************
        // Signals
        //***************

        private:
            //Nymph::KTSignalData fVecSignal;

        //***************
        // Slots
        //***************

        private:
            //Nymph::KTSlotDataOneType< KTSliceHeader > fHeaderSlot;
            Nymph::KTSlotDataTwoTypes< KTSliceHeader, KTPowerSpectrumData > fPSSlot;
            Nymph::KTSlotDone fDoneSlot;
    };

}

#endif /* KTRFSLEWTOACQ_HH_ */
