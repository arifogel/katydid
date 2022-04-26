/*
 * KTGainVariationDiffProcessor.cc
 *
 *  Created on: April 25 2022
 *      Author: H. Harrington
 */

#include "KTGainVariationDiffProcessor.hh"

#include "KTGainVariationData.hh"
#include "KTSpline.hh"
#include "KTStdComplexFuncs.hh"

#include <cmath>
#include <complex>
#include <vector>

#ifdef USE_OPENMP
#include <omp.h>
#endif

using std::string;
using std::vector;


namespace Katydid
{
    KTLOGGER(gvlog, "KTGainVariationDiffProcessor");

    KT_REGISTER_PROCESSOR(KTGainVariationDiffProcessor, "gain-variation-difference");

    KTGainVariationDiffProcessor::KTGainVariationDiffProcessor(const std::string& name) :
            KTProcessor(name),
            fMinBin(0),
            fMaxBin(1),
            fNFitPoints(5),
            fGainVarSignal("gain-var", this),

            fPreCalcSlotOne("gv1", this, &KTGainVariationDiffProcessor::SetPreCalcGainVarOne),
            fPreCalcSlotTwo("gv2", this, &KTGainVariationDiffProcessor::SetPreCalcGainVarTwo)
    {
    }

    KTGainVariationDiffProcessor::~KTGainVariationDiffProcessor()
    {
    }

    bool KTGainVariationDiffProcessor::Configure(const scarab::param_node* node)
    {
        if (node == NULL) return false;

        // The if(has) pattern is used here so that Set[whatever] is only called if the particular parameter is present.
        // These Set[whatever] functions also set the flags to calculate the min/max bin, so we only want to call them if we are setting the value, and not just keeping the existing value.
        if (node->has("min-bin"))
        {
            SetMinBin(node->get_value< unsigned >("min-bin"));
        }
        if (node->has("max-bin"))
        {
            SetMaxBin(node->get_value< unsigned >("max-bin"));
        }

        SetNFitPoints(node->get_value< unsigned >("fit-points", fNFitPoints));
        return true;
    }

    bool KTGainVariationDiffProcessor::SetPreCalcGainVarOne(KTGainVariationData& gvData1)
    {
        fGVData1 = gvData1;
        return true;
    }

    bool KTGainVariationDiffProcessor::SetPreCalcGainVarTwo(KTGainVariationData& gvData2)
    {
        fGVData2 = gvData2;
        return true;
    }

    bool KTGainVariationDiffProcessor::Run()
    {
        return CalculateDifference(fGVData1, fGVData2);
    }

    bool KTGainVariationDiffProcessor::CalculateDifference(KTGainVariationData& gvData1, KTGainVariationData& gvData2)
    {

        unsigned nComponents = gvData1.GetNComponents();
        for (unsigned iComponent=0; iComponent<nComponents; ++iComponent)
        {

            Nymph::KTDataPtr data( new Nymph::KTData() );
            KTGainVariationData& newData = data->Of< KTGainVariationData >().SetNComponents(gvData1.GetNComponents());

            //KTGainVariationData newData = new KTGainVariationData();

            unsigned nBins = fMaxBin - fMinBin + 1;
            //unsigned nBinsPerFitPoint = nTotalBins / fNFitPoints; // integer division rounds down; there may be bins leftover unused

            KTSpline* meanSpline1 = gvData1.GetSpline(iComponent);
            KTSpline* meanSpline2 = gvData2.GetSpline(iComponent);
            KTSpline* varSpline1 = gvData1.GetVarianceSpline(iComponent);
            KTSpline* varSpline2 = gvData2.GetVarianceSpline(iComponent);

            double freqMin1 = gvData1.GetSpline()->GetXMin(); 
            double freqMin2 = gvData2.GetSpline()->GetXMin();
            double freqMax1 = gvData1.GetSpline()->GetXMax(); 
            double freqMax2 = gvData2.GetSpline()->GetXMax();

            double xmin = std::max(freqMin1,freqMin2);
            double xmax = std::min(freqMax1,freqMax1);

            double freqBinWidth = (xmax-xmin)/nBins;

            if (freqMin1 != freqMin2)
            {
                KTDEBUG(gvlog, "Two splines do not share the same xmin. Using higher" << xmin );
            }

            if (freqMax1 != freqMax2)
            {
                KTDEBUG(gvlog, "Two splines do not share the same xmax. Using lower" << xmax );
            }

            std::shared_ptr< KTSpline::Implementation > meanspline1Imp = meanSpline1->Implement(nBins, xmin, xmax);
            std::shared_ptr< KTSpline::Implementation > meanspline2Imp = meanSpline2->Implement(nBins, xmin, xmax);
            std::shared_ptr< KTSpline::Implementation > varSpline1Imp = varSpline1->Implement(nBins, xmin, xmax);
            std::shared_ptr< KTSpline::Implementation > varSpline2Imp = varSpline2->Implement(nBins, xmin, xmax);
            
            double* xVals = new double[nBins];
            double* yValsMean = new double[nBins];
            double* yValsVar = new double[nBins];

            KTDEBUG(gvlog, "Subtracting two splines. ");
            // loop over bins, subtract implementations
    #pragma omp parallel for private(value)
                for (unsigned iBin=0; iBin<=nBins; ++iBin)
                {
                    double mean1 = (*meanspline1Imp)(iBin - fMinBin);
                    double mean2 = (*meanspline2Imp)(iBin - fMinBin);
                    double variance1 = (*varSpline1Imp)(iBin - fMinBin);
                    double variance2 = (*varSpline2Imp)(iBin - fMinBin);

                    yValsMean[iBin] = mean1-mean2;
                    yValsVar[iBin] = variance1+variance2;
                    xVals[iBin] = xmin+iBin*freqBinWidth;
                }

            // Calculate new splines
            KTSpline* newMeanSpline = new KTSpline(xVals, yValsMean, fNFitPoints);
            newMeanSpline->SetXMin(xmin);
            newMeanSpline->SetXMax(xmax);

            KTSpline* newVarSpline = new KTSpline(xVals, yValsVar, fNFitPoints);
            newVarSpline->SetXMin(xmin);
            newVarSpline->SetXMax(xmax);

            delete [] xVals;
            delete [] yValsMean;
            delete [] yValsVar;

            newData.SetSpline(newMeanSpline, iComponent);
            newData.SetVarianceSpline(newVarSpline, iComponent);
        }
        KTINFO(gvlog, "Completed gain variation differencce calculation for " << nComponents);

        return true;
    }

} /* namespace Katydid */
