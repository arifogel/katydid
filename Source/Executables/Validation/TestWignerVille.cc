/*
 * TestWignerVille.cc
 *
 *  Created on: Nov 6, 2012
 *      Author: nsoblath
 *
 *  Usage:
 *      > TestWignerVille
 */

#include "KTAnalyticAssociateData.hh"
#include "KTAnalyticAssociator.hh"
#include "KTFrequencySpectrumPolar.hh"
#include "KTFrequencySpectrumDataFFTW.hh"
#include "KTFrequencySpectrumFFTW.hh"
#include "KTLogger.hh"
#include "KTMath.hh"
#include "KTTimeSeriesFFTW.hh"
#include "KTTimeSeriesReal.hh"
#include "KTWignerVille.hh"
#include "KTWignerVilleData.hh"

#ifdef ROOT_FOUND
#include "TFile.h"
#include "TH2.h"
#include "TH1.h"
#endif


using namespace Katydid;
using namespace std;

KTLOGGER(testlog, "TestWignerVille");

int main()
{
    unsigned nTimeBins = 32768;

    double amplitude = 1.;
    double startFreq = 2000.; // Hz
    double deltaFreq = -10.; // Hz
    double twoPi = 2. * KTMath::Pi();

    KTTimeSeriesReal* ts1 = new KTTimeSeriesReal(nTimeBins, 0., 1.);
    KTTimeSeriesReal* ts2 = new KTTimeSeriesReal(nTimeBins, 0., 1.);
    for (unsigned iBin=0; iBin<nTimeBins; iBin++)
    {
        double freq = startFreq + double(iBin)/1000. * deltaFreq;
        double binCent = ts1->GetBinCenter(iBin);
        ts1->SetValue(iBin, amplitude * sin(twoPi * freq * binCent));
        ts2->SetValue(iBin, amplitude * sin(twoPi * freq * binCent));
    }

#ifdef ROOT_FOUND
    TFile* file = new TFile("testWignerVille.root", "recreate");

    TH1D* hTS = ts1->CreateHistogram();
    hTS->Write();
#endif


    unsigned wvSize = 512;

    KTAnalyticAssociator aAssociator;
    aAssociator.GetForwardFFT()->SetTransformFlag("ESTIMATE");
    aAssociator.GetForwardFFT()->SetTimeSize(wvSize);
    aAssociator.GetForwardFFT()->InitializeForRealAsComplexTDD();
    aAssociator.GetReverseFFT()->SetTransformFlag("ESTIMATE");
    aAssociator.GetReverseFFT()->SetTimeSize(wvSize);
    aAssociator.GetReverseFFT()->InitializeForComplexTDD();

    KTWignerVille wvTransform;
    wvTransform.GetFFT()->SetTransformFlag("ESTIMATE");
    wvTransform.GetFFT()->SetTimeSize(/*2 */ wvSize);
    wvTransform.GetFFT()->InitializeForComplexTDD();
    wvTransform.AddPair(KTWignerVille::UIntPair(0, 1));

    // Initialize() sets up the output data containers (fOutputSHData/fOutputWVData) that
    // TransformData() requires; without it, TransformData() fails on every call. SetWindowSize()
    // must be called first, since Initialize() reconfigures the FFT using its own fWindowSize
    // member rather than the size set on wvTransform.GetFFT() above.
    wvTransform.SetWindowSize(wvSize);
    wvTransform.Initialize(1. / ts1->GetBinWidth(), 2, wvSize);

    unsigned nWindows = nTimeBins / wvSize;

    vector< KTWignerVilleData* > allOutput(nWindows);
    KTPhysicalArray< 1, KTFrequencySpectrumFFTW* > spectra(nWindows, 0., 1.);

    KTINFO(testlog, nWindows << " will be used");

    KTSliceHeader header;

    unsigned iWindow = 0;
    for (unsigned windowStart = 0; windowStart < wvSize * nWindows; windowStart += wvSize)
    {
        KTINFO(testlog, "window: " << iWindow);
        //KTBasicTimeSeriesData windowData(2);
        KTTimeSeriesReal* windowTS1 = new KTTimeSeriesReal(wvSize, ts1->GetBinLowEdge(windowStart), ts1->GetBinLowEdge(windowStart) + ts1->GetBinWidth() * (double)wvSize);
        KTTimeSeriesReal* windowTS2 = new KTTimeSeriesReal(wvSize, ts2->GetBinLowEdge(windowStart), ts2->GetBinLowEdge(windowStart) + ts2->GetBinWidth() * (double)wvSize);

        for (unsigned iBin=windowStart; iBin < windowStart+wvSize; iBin++)
        {
            windowTS1->SetValue(iBin-windowStart, ts1->GetValue(iBin));
            windowTS2->SetValue(iBin-windowStart, ts2->GetValue(iBin));
        }

        //windowData.SetTimeSeries(windowTS1, 0);
        //windowData.SetTimeSeries(windowTS2, 1);

        //KTTimeSeriesData* aaTSData = aAssociator.CreateAssociateData(&windowData);
        KTTimeSeriesFFTW* aaTS1 = aAssociator.CalculateAnalyticAssociate(windowTS1);
        KTTimeSeriesFFTW* aaTS2 = aAssociator.CalculateAnalyticAssociate(windowTS2);

        // aaData is heap-allocated and intentionally never deleted. KTExtensibleStructCore's
        // destructor deletes its chained extended-struct components, so a stack-allocated
        // aaData would delete the KTWignerVilleData object referenced by allOutput[iWindow] and
        // spectra(iWindow) below as soon as this scope exits. Those components are deleted
        // explicitly, by pointer, in the cleanup loop further down.
        KTAnalyticAssociateData* aaData = new KTAnalyticAssociateData();
        aaData->SetNComponents(2);
        aaData->SetTimeSeries(aaTS1, 0);
        aaData->SetTimeSeries(aaTS2, 1);
        //aaTSData->SetTimeSeries(windowTS1, 0);
        //aaTSData->SetTimeSeries(windowTS2, 1);

        if (! wvTransform.TransformData(*aaData, header))
        {
            KTERROR(testlog, "Something went wrong while computing the Wigner-Ville transform");
        }
        KTWignerVilleData& output = aaData->Of< KTWignerVilleData >();

        allOutput[iWindow] = &output;
        spectra(iWindow) = output.GetSpectrumFFTW(0);

        delete windowTS1;
        delete windowTS2;

        iWindow++;
    }

#ifdef ROOT_FOUND
    // The Wigner-Ville transform correlates across time slices, so the first window (an empty
    // circular buffer being filled for the first time) does not produce an output spectrum,
    // even though TransformData() reports success for that call. spectra(0) is therefore not
    // guaranteed to be valid; use the first non-null entry instead, and skip null entries when
    // filling the histogram.
    unsigned nBinsX = spectra.size();
    unsigned firstValid = nBinsX;
    for (unsigned iX = 0; iX < nBinsX; ++iX)
    {
        if (spectra(iX) != NULL)
        {
            firstValid = iX;
            break;
        }
    }
    if (firstValid == nBinsX)
    {
        KTERROR(testlog, "No window produced a Wigner-Ville spectrum; skipping histogram output");
    }
    else
    {
        unsigned nBinsY = spectra(firstValid)->size();
        TH2D* histOut = new TH2D("wv", "Wigner-Ville", nBinsX, spectra.GetRangeMin(), spectra.GetRangeMax(), nBinsY, spectra(firstValid)->GetRangeMin(), spectra(firstValid)->GetRangeMax());
        double value;
        for (unsigned iX=0; iX<nBinsX; iX++)
        {
            KTFrequencySpectrumFFTW* spectrum = spectra(iX);
            if (spectrum == NULL) continue;
            for (unsigned iY=0; iY<nBinsY; iY++)
            {
                value = sqrt((*spectrum)(iY)[0] * (*spectrum)(iY)[0] + (*spectrum)(iY)[1] * (*spectrum)(iY)[1]);
                histOut->SetBinContent(iX+1, iY+1, value);
            }
        }
        histOut->Write();
    }
#endif

    for (unsigned iWindow=0; iWindow < nWindows; iWindow++)
    {
        delete allOutput[iWindow];
        spectra(iWindow) = NULL;
    }

    delete ts1;
    delete ts2;

#ifdef ROOT_FOUND
    file->Close();
    delete file;
#endif

    return 0;

}
