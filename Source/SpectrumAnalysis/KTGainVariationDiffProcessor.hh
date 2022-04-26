/**
 @file KTGainVariationDiffProcessor.hh
 @brief Contains KTGainVariationDiffProcessor
 @details Takes output from two gain variation processors and outputs the difference.
 @author: H. Harrington
 @date: April 25 2022
 */

#ifndef KTGAINVARIATIONDIFFPROCESSOR_HH_
#define KTGAINVARIATIONDIFFPROCESSOR_HH_

#include "KTProcessor.hh"
#include "KTGainVariationData.hh"
#include "KTPhysicalArray.hh"
#include "KTSlot.hh"

#include <fftw3.h>

#include <list>

namespace Katydid
{

    class KTGainVariationData;

    //class KTSpline;

    /*!
     @class KTGainVariationDiffProcessor
     @author H. Harrington

     @brief Takes two KTGainVariationData objects and returnes the difference.

     @details
     For each KTGainVariationData objects the splines for the mean and variance are implemented.
     It then loops over the number of bins, subtracts the mean1-mean2 and adds var1+var2.
     These arrays are then fit to new splines used to buid a new KTGainVariationData object.
     The spline fit is performed between fMinBin and fMaxBin, inclusive.

     Configuration name: "gain-variation-difference"

     Available configuration values:
     - "min-bin": unsigned -- minimum bin for the fit
     - "max-bin": unsigned -- maximum bin for the fit
     - "fit-points": unsigned -- number of bins to use to make the new spline

     Slots:
     - "gv1": void (Nymph::KTDataPtr) -- Sets the first pre-calculated gain-variation data; Requires KTGainVariationData
     - "gv2": void (Nymph::KTDataPtr) -- Sets the second pre-calculated gain-variation data; Requires KTGainVariationData

     Signals:
     - "gain-var": void (Nymph::KTDataPtr) emitted upon performance of a fit to the difference; Guarantees KTGainVariationData
    */

    class KTGainVariationDiffProcessor : public Nymph::KTProcessor
    {
        public:
            KTGainVariationDiffProcessor(const std::string& name = "gain-variation-difference");
            virtual ~KTGainVariationDiffProcessor();

            bool Configure(const scarab::param_node* node);

            unsigned GetMinBin() const;
            void SetMinBin(unsigned bin);

            unsigned GetMaxBin() const;
            void SetMaxBin(unsigned bin);

            unsigned GetNFitPoints() const;
            void SetNFitPoints(unsigned nPoints);

        private:
            unsigned fMinBin;
            unsigned fMaxBin;
            unsigned fNFitPoints;

            KTGainVariationData fGVData;
            KTGainVariationData fGVData1;
            KTGainVariationData fGVData2;

  
        public:
            bool Run();
            bool SetPreCalcGainVarOne(KTGainVariationData& gvData1);
            bool SetPreCalcGainVarTwo(KTGainVariationData& gvData2);

            bool CalculateDifference(KTGainVariationData& gvData1, KTGainVariationData& gvData2);

        //***************
        // Signals
        //***************

        private:
            Nymph::KTSignalData fGainVarSignal;

        //***************
        // Slots
        //***************

        private:
            Nymph::KTSlotDataOneType< KTGainVariationData > fPreCalcSlotOne;
            Nymph::KTSlotDataOneType< KTGainVariationData > fPreCalcSlotTwo;

    };


    inline unsigned KTGainVariationDiffProcessor::GetMinBin() const
    {
        return fMinBin;
    }

    inline void KTGainVariationDiffProcessor::SetMinBin(unsigned bin)
    {
        fMinBin = bin;
        return;
    }

    inline unsigned KTGainVariationDiffProcessor::GetMaxBin() const
    {
        return fMaxBin;
    }

    inline void KTGainVariationDiffProcessor::SetMaxBin(unsigned bin)
    {
        fMaxBin = bin;
        return;
    }

    inline unsigned KTGainVariationDiffProcessor::GetNFitPoints() const
    {
        return fNFitPoints;
    }

    inline void KTGainVariationDiffProcessor::SetNFitPoints(unsigned nPoints)
    {
        fNFitPoints = nPoints;
    }


} /* namespace Katydid */
#endif /* KTGAINVARIATIONDIFFPROCESSOR_HH_ */
