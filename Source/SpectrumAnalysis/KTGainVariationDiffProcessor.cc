/*
 * KTGainVariationDiffProcessor.cc
 *
 *  Created on: April 25 2022
 *      Author: H. Harrington
 */

#include "KTGainVariationDiffProcessor.hh"

#include "KTGainVariationData.hh"
#include "KTSpline.hh"

#include <cmath>
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
            fGainCoeff(1),
            NumGVDataArrived(0),
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

        SetGainCoeff(node->get_value< int >("gain-coeff", fGainCoeff));

        return true;
    }

    bool KTGainVariationDiffProcessor::SetPreCalcGainVarOne(KTGainVariationData& gvData1)
    {
        fGVData1 = gvData1;
        if (NumGVDataArrived == 0 ){
            NumGVDataArrived = 1;
            return true;
        }
        
        return CalculateDifference();
    }

    bool KTGainVariationDiffProcessor::SetPreCalcGainVarTwo(KTGainVariationData& gvData2)
    {
        fGVData2 = gvData2;
        if (NumGVDataArrived == 0 ){
            NumGVDataArrived = 1;
            return true;
        }
        
        return CalculateDifference();
    }

    bool KTGainVariationDiffProcessor::CalculateDifference()
    {
        Nymph::KTDataPtr data( new Nymph::KTData() );
        KTGainVariationData& newData = data->Of< KTGainVariationData >().SetNComponents(fGVData1.GetNComponents());

        unsigned nComponents = fGVData1.GetNComponents();
        for (unsigned iComponent=0; iComponent<nComponents; ++iComponent)
        {

            //KTGainVariationData newData = new KTGainVariationData();

            unsigned nBins = fMaxBin - fMinBin + 1;
            //unsigned nBinsPerFitPoint = nTotalBins / fNFitPoints; // integer division rounds down; there may be bins leftover unused

            KTSpline* meanSpline1 = fGVData1.GetSpline(iComponent);
            KTSpline* meanSpline2 = fGVData2.GetSpline(iComponent);
            KTSpline* varSpline1 = fGVData1.GetVarianceSpline(iComponent);
            KTSpline* varSpline2 = fGVData2.GetVarianceSpline(iComponent);

            double freqMin1 = fGVData1.GetSpline()->GetXMin(); 
            double freqMin2 = fGVData2.GetSpline()->GetXMin();
            double freqMax1 = fGVData1.GetSpline()->GetXMax(); 
            double freqMax2 = fGVData2.GetSpline()->GetXMax();

            double xmin = std::max(freqMin1,freqMin2);
            double xmax = std::min(freqMax1,freqMax1);

            double freqBinWidth = (xmax-xmin)/nBins;
            KTDEBUG(gvlog, "freqBinWidth: " << freqBinWidth );

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
            
            vector<double> xVals(nBins);
            vector<double> yValsMean(nBins);
            vector<double> yValsVar(nBins);

            KTDEBUG(gvlog, "Subtracting two splines. ");
            // loop over bins, subtract implementations
    #pragma omp parallel for private(value)
                for (unsigned iBin=0; iBin<nBins; ++iBin)
                {
                    double mean1 = (*meanspline1Imp)(iBin);
                    double mean2 = (*meanspline2Imp)(iBin);
                    double variance1 = (*varSpline1Imp)(iBin);
                    double variance2 = (*varSpline2Imp)(iBin);

                    //KTDEBUG(gvlog, "mean1: " << mean1 << " mean2: " << mean2 );

                    yValsMean[iBin] = mean1-fGainCoeff*mean2;
                    //KTDEBUG(gvlog, "yValsMean: " << yValsMean[iBin] );
                    yValsVar[iBin] = variance1+variance2;
                    xVals[iBin] = xmin+iBin*freqBinWidth;
                    KTDEBUG(gvlog, "Fit point: " << iBin << " " << mean1 << " " << mean2 <<  " " << xVals[iBin] << " " << yValsMean[iBin] );
                }

            // Calculate new splines
            KTDEBUG(gvlog, "Fitting new spline with " << nBins << " fit points." );
            KTSpline* newMeanSpline = new KTSpline(xVals.data(), yValsMean.data(), nBins);
            newMeanSpline->SetXMin(xmin);
            newMeanSpline->SetXMax(xmax);

            KTSpline* newVarSpline = new KTSpline(xVals.data(), yValsVar.data(), nBins);
            newVarSpline->SetXMin(xmin);
            newVarSpline->SetXMax(xmax);

            //make implementation of spline to check
            //std::shared_ptr< KTSpline::Implementation > newMeanSplineImp = newMeanSpline->Implement(12, 0, nBins);

            newData.SetSpline(newMeanSpline, iComponent);
            newData.SetVarianceSpline(newVarSpline, iComponent);
        }
        KTINFO(gvlog, "Completed gain variation differencce calculation for " << nComponents);

        fGainVarSignal(data);
        NumGVDataArrived = 0;
        return true;
    }

} /* namespace Katydid */
