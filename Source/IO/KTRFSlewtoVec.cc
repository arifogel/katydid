/*
 * KTRFSlewtoVec.hh
 *
 *  Created on: May 1, 2023
 *      Author: Heather Harrington
 */

#include "KTRFSlewtoVec.hh"

#include "KTMath.hh"
#include "KTPowerSpectrum.hh"
#include "KTPowerSpectrumData.hh"
#include "KTLogger.hh"
#include "KTSliceHeader.hh"
#include "KTPowerSpectrumData.hh"
#include <numeric>

namespace Katydid
{
    KTLOGGER(slewlog, "KTRFSlewtoVec");

    // Register the processor
    KT_REGISTER_PROCESSOR(KTRFSlewtoVec, "rf-slew-to-vec");

    KTRFSlewtoVec::KTRFSlewtoVec(const std::string& name) :
            KTProcessor(name),
            fPriorSlices({1.0,1.0,1.0,1.0,1.0,1.0,1.0}),
            fPriorMean(1),
            fSlewEndTimes(),
            fSlewStartTimes(),
            fFilename("SlewTimes.txt"),
            //fVecSignal("slew-vec", this),
            fPSSlot("ps", this, &KTRFSlewtoVec::GetOnOffTimes),
            fDoneSlot("done", this, &KTRFSlewtoVec::RunIsOver)
    {
    }

    KTRFSlewtoVec::~KTRFSlewtoVec()
    {
    }

    bool KTRFSlewtoVec::Configure(const scarab::param_node* node)
    {
        if (node == NULL) return false;

        SetFilename(node->get_value("output-file", fFilename));
        
        return true;
    }

    bool KTRFSlewtoVec::GetOnOffTimes(KTSliceHeader& slHeader, KTPowerSpectrumData& spectrum)
    {
        uint64_t isTrapOff = slHeader.GetIsTrapOff();
        uint64_t sliceNum = slHeader.GetSliceNumber();
        double timeInRun = slHeader.GetTimeInRun();

        //update vector of last 5 slice on/off status
        fPriorSlices.erase(fPriorSlices.begin());
        fPriorSlices.push_back(isTrapOff);

        auto const count = static_cast<float>(fPriorSlices.size());
        double mean = std::round(std::accumulate(fPriorSlices.begin(), fPriorSlices.end(),0) / count);

        if (mean != fPriorMean)
        {
            if (isTrapOff == 0){
                if (sliceNum <= count){
                    fSlewStartTimes.push_back(0);
                }
                else fSlewStartTimes.push_back(timeInRun);
            }
            else fSlewEndTimes.push_back(timeInRun);

            KTDEBUG(slewlog, "Slew break detected at " << timeInRun);
        }

        fPriorMean = mean;
        return true;
    }

    // return reference to vector that is recived by a pointer
    void KTRFSlewtoVec::RunIsOver()
    {
        KTINFO(slewlog, "Got spec-done signal. Returning finished vector of slew start and end times.");
        KTINFO(slewlog, "Writing to file" << fFilename);
        //temp: write vector to file for testing
        std::ofstream outFile(fFilename);
        outFile << "Time_On,Time_Off\n";
        KTINFO(slewlog, "fSlewEndTimes length: " << fSlewEndTimes.size());
        if (fSlewEndTimes.size() > 0 ){
            for (int i = 0; i < fSlewStartTimes.size(); i++){
                outFile << fSlewStartTimes[i] << "," << fSlewEndTimes[i] << "\n";
            }
        }
        else{
            outFile << 0 << "," << 1 << "\n";
        }
        //return fSlewStartEndTimes;
    }


} // namespace Katydid
