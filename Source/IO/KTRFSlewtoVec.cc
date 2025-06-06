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
#include <fstream>
#include <numeric>

namespace Katydid
{
    KTLOGGER(slewlog, "KTRFSlewtoVec");

    // Register the processor
    KT_REGISTER_PROCESSOR(KTRFSlewtoVec, "rf-slew-to-vec");

    KTRFSlewtoVec::KTRFSlewtoVec(const std::string& name) :
            KTProcessor(name),
            fNumRunAvg(1),
            fPriorMean(1),
            fAcqEndTimes(),
            fAcqStartTimes(),
            fPriorSlices({1.0}),
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
        fNumRunAvg = node->get_value< int >("num-for-run-avg", fNumRunAvg);
        // Create a vector filled with fNumRunAvg elements, all initialized to 1.0
        std::vector<double> fPriorSlices(fNumRunAvg, 1.0);
        
        return true;
    }

    bool KTRFSlewtoVec::GetOnOffTimes(KTSliceHeader& slHeader, KTPowerSpectrumData& spectrum)
    {
        uint64_t isTrapOff = slHeader.GetIsTrapOff();
        uint64_t sliceNum = slHeader.GetSliceNumber();
        double timeInRun = slHeader.GetTimeInRun();

        // update vector of last 5 slice on/off status
        fPriorSlices.erase(fPriorSlices.begin());
        fPriorSlices.push_back(isTrapOff);

        auto const count = static_cast<float>(fPriorSlices.size());
        double mean = std::round(std::accumulate(fPriorSlices.begin(), fPriorSlices.end(),0) / count);

        if (mean != fPriorMean) // Detects a trap state change (smoothed)
        {
            if (isTrapOff == 0){
                if (sliceNum <= count){
                    fAcqStartTimes.push_back(0);
                }
                else fAcqStartTimes.push_back(timeInRun);
                fCurrentAcqID++ ; // new acquisition started
            }
            else fAcqEndTimes.push_back(timeInRun);

            KTDEBUG(slewlog, "Slew break detected at " << timeInRun);
        }
        // if you haven’t yet hit a clear transition to acquisition start, you're still in acquisition 0
        if (fAcqStartTimes.empty()){ 
            slHeader.SetAcquisitionID(0);
            slHeader.SetTimeInAcq(timeInRun-0); // time since start of run
        }
        else{
            slHeader.SetAcquisitionID(fCurrentAcqID);
            slHeader.SetTimeInAcq(timeInRun-fAcqStartTimes.back());
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
        KTINFO(slewlog, "fAcqEndTimes length: " << fAcqEndTimes.size());
        if (fAcqEndTimes.size() > 0 ){
            for (int i = 0; i < fAcqStartTimes.size(); i++){
                outFile << fAcqStartTimes[i] << "," << fAcqEndTimes[i] << "\n";
            }
        }
        else{
            outFile << 0 << "," << 1 << "\n";
        }
        //return fSlewStartEndTimes;
    }


} // namespace Katydid
