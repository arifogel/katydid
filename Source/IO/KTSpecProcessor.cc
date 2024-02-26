#include <iostream>
#include <fstream>
#include "KTSpecProcessor.hh"
#include "KTCommandLineOption.hh"
#include "KTData.hh"
#include "KTSliceHeader.hh"
#include "KTPowerSpectrum.hh"
#include "KTPowerSpectrumData.hh"
#include <bitset>

using std::string;
using namespace std;

namespace Katydid
{
    static Nymph::KTCommandLineOption< string > sFilenameCLO("Spec Processor", "Spec filename to open", "spec-file", 's');

    KTLOGGER(speclog, "KTSpecProcessor");

    KT_REGISTER_PROCESSOR(KTSpecProcessor, "spec-processor");

    KTSpecProcessor::KTSpecProcessor(const std::string& name) :
            KTPrimaryProcessor(name),
            fProgressReportInterval(1),
            fFilenames(),
            fFreqBins(8192),
            fNSpectra(0),
            fPacketIDOffset(9),
            fPacketHeaderSize(32),
            fFreqMin(0.),
            fFreqMax(2400000000),
            fBinTOff(342),          //the trap off signal frequency bin
            fBinTOffPow(20),
            fROACH_FFT_Avg(2),      //the number of sequential FFTs averaged on the DAQ before output to *.spec
            fSpecFreqAvg(1),        //the number of freq bins to average (for improving SNR with nonzero df/dt)
            fSpecs(),
            fDataSignal("ps", this),
            fSpecDoneSignal("spec-done", this)
    {
    }

    KTSpecProcessor::~KTSpecProcessor()
    {
    }

    bool KTSpecProcessor::Configure(const scarab::param_node* node)
    {
        // Config-file settings
        if (node != NULL)
        {
            if (node->has("filenames"))
            {
                KTDEBUG(speclog, "Adding multiple files to spec processor");
                fFilenames.clear();
                const scarab::param_array* t_filenames = node->array_at("filenames");
                for(scarab::param_array::const_iterator t_file_it = t_filenames->begin(); t_file_it != t_filenames->end(); ++t_file_it)
                {
                    fFilenames.push_back( std::move(scarab::expand_path((*t_file_it)->as_value().as_string())) );
                    KTINFO(speclog, "Added file to spec processor: <" << fFilenames.back() << ">");
                }
            }
            else if (node->has("filename"))
            {
                KTDEBUG(speclog, "Adding single file to spec processor");
                fFilenames.clear();
                fFilenames.push_back( std::move(scarab::expand_path(node->get_value( "filename" ))) );
                KTINFO(speclog, "Added file to spec processor: <" << fFilenames.back() << ">");
            }

            fNSpectra = node->get_value< unsigned >("spectra", fNSpectra);
            KTINFO(speclog, "Number of spectra = " << fNSpectra);
            fPacketIDOffset = node->get_value< unsigned >("packet-ID-offset", fPacketIDOffset);
            fPacketHeaderSize = node->get_value< unsigned >("header-bytes", fPacketHeaderSize);
            fROACH_FFT_Avg = node->get_value< unsigned >("ROACH-spect-avg", fROACH_FFT_Avg);
            fFreqBins = node->get_value< unsigned >("freq-bins", fFreqBins); //total bins
            fFreqMin = node->get_value< double >("min-freq", fFreqMin);
            fFreqMax = node->get_value< double >("max-freq", fFreqMax);
            KTINFO(speclog, "Maximum frequency = " << fFreqMax);
            fBinTOff = node->get_value< int >("TOff-bin", fBinTOff);
            fBinTOffPow = node->get_value< int >("TOff-bin-pow", fBinTOffPow);
            fSpecFreqAvg = node->get_value< unsigned >("freq-bin-avg", fSpecFreqAvg);
        }

        // Command-line settings
        if (fCLHandler->IsCommandLineOptSet("spec-file"))
        {
            KTDEBUG(speclog, "Adding single file to spec processor from the CL");
            fFilenames.clear();
            fFilenames.push_back( std::move(scarab::expand_path(fCLHandler->GetCommandLineValue< string >("spec-file"))));
            KTINFO(speclog, "Added file to spec processor: <" << fFilenames.back() << ">");
        }

        return true;
    }

    int KTSpecProcessor::PacketNumber(char *aBufferPointer)
    {
        int pkt_num = bitset<8>(uint8_t(*(aBufferPointer + fPacketIDOffset))).to_ulong() * pow(2,16);
        pkt_num += bitset<8>(uint8_t(*(aBufferPointer + fPacketIDOffset + 1))).to_ulong() * pow(2,8);
        pkt_num += bitset<8>(uint8_t(*(aBufferPointer + fPacketIDOffset + 2))).to_ulong();
        return pkt_num;
    }

    bool KTSpecProcessor::ProcessSpec()
    {
        if (fFilenames.size() == 0)
        {
            KTERROR(speclog, "No files have been specified");
            return false;
        }

        if (fFilenames.size() > 2)
        {
            KTERROR(speclog, "More than 2 spec simultaneous files have been specified! We don't have that much bandwidth!");
            return false;
        }

        //check if fSpecFreqAvg divides fFreqBins evenly
        if(fFreqBins % fSpecFreqAvg != 0)
            KTWARN(speclog, "freq-bin-avg does not divide freq-bins!");

        const unsigned fEffectiveFreqBins = fFreqBins / fSpecFreqAvg;

        const int nChannels = fFilenames.size();
        //check if fFreqBins divides nChannels evenly
        if(fEffectiveFreqBins % nChannels != 0)
            KTWARN(speclog, "nChannels does not divide (effective) freq-bins!");

        const int nBins = fFreqBins / nChannels; // number of frequency bins per channel
        const int nPacketSize = fPacketHeaderSize + nBins; // could use reconfiguration (user config) if more general case wanted
        KTINFO(speclog, "Packet Size: "<<nPacketSize);

        // For file j, j*fBinOffsetPerFile is added to the bin numbers to files are not "on top of each other"
        const unsigned fBinOffsetPerFile = fEffectiveFreqBins / nChannels;

        // Open the .spec files
        for(unsigned i = 0; i <fFilenames.size(); ++i)
        {
            KTINFO(speclog, "Opening spec file <" << fFilenames[i] << ">");
            if(fFilenames[i].extension() != ".spec")
                KTFATAL(speclog, fFilenames[i] <<" is not a .spec file!");

            // open the file and load its full contents into memblock
            fSpecs.emplace_back(fFilenames[i], nPacketSize);
            if(!fSpecs[i].file.is_open())
            {
                KTFATAL(speclog, fFilenames[i] <<" is failed to open!");
            }
            else
            {
                KTINFO(speclog, "Spec file <" << fFilenames[i] << "> opened");
            }
        }

        //spectra must be treated as unsigned 8-bit values (0-255)
        int slice[fEffectiveFreqBins]; //holder array for spectrum data, set to all zeros
        std::fill(slice, slice + fEffectiveFreqBins, 0);

        vector <KTPowerSpectrum*> newSpec(1);
        vector<int> pkt_num(fNSpectra);
        unsigned binOffset;

        //loop over # of spectra to be read
        for(int i = 0; i < fNSpectra; ++i)
        {
            if (i == 0) KTINFO(speclog, "Preparing to read first spectrum");

            for(unsigned j = 0; j < nChannels; ++j)
            {
                fSpecs[j].file.read(fSpecs[j].pointer, nPacketSize); //read full packet into buffer at position pointer
            }

            pkt_num[i] = PacketNumber(fSpecs[0].pointer);
            KTINFO(speclog, "Decimal pkt_num = " << pkt_num[i]);

            //Check if sequential spectra have correct packet numbers
            if (i>0)
            {
                // Both fPacketsPerSpectrum and fSpecTimeAvg are forced to be 1, for now in speck_processor
                int adjusted_pkt_num = (pkt_num[i-1] + 1) % 1048576; //2^20, max packet number for 2^12 bitcode
                if(pkt_num[i] - adjusted_pkt_num != 0)
                    KTWARN(speclog, "WARNING: " << pkt_num[i]-adjusted_pkt_num << " packets dropped!");
            }
            //Check if simultaneous spectra have correct packet numbers
            if(nChannels == 2  && (pkt_num[i] != PacketNumber(fSpecs[1].pointer)))
                KTFATAL(speclog, "You have packet shear between spectrogram  files! Incompatible files!");

            std::fill(slice, slice + fEffectiveFreqBins, 0);

            for(unsigned j = 0; j < nChannels; ++j)
            { 
                binOffset = j*fBinOffsetPerFile;
                for(unsigned k = 0; k < nBins; ++k)
                    slice[k/fSpecFreqAvg + binOffset] += fSpecs[j].buffer[fPacketHeaderSize + k];
            }

            unsigned comp = 0;
            //initialize an object of type KTPowerSpectrum with all 0
            //values and 8192 Bins from 0 to 1600 MHz
            Nymph::KTDataPtr data(new Nymph::KTData());

            KTSliceHeader& sliceHeader = data->Of< KTSliceHeader >().SetNComponents(1);

            if (slice[fBinTOff] > fBinTOffPow)
            {
                sliceHeader.SetIsTrapOff(1);
                //KTINFO(speclog, "Set trap off!");
            }
            else sliceHeader.SetIsTrapOff(0);

            sliceHeader.SetSliceNumber(i);

            sliceHeader.SetPacketNumber(pkt_num[i]);

            //slice size in bytes = # of bins (given 8-bit resolution)
            sliceHeader.SetRawSliceSize(fEffectiveFreqBins);

            //no diff between 'raw' slice size, slice size
            sliceHeader.SetSliceSize(fFreqBins);

            //Nyquist frequency is 1/2 sampling rate
            sliceHeader.SetSampleRate(2*fFreqMax);
            KTINFO(speclog, "Frequency max = " << fFreqMax);

            //slice length is 2x # of bins / 2x Nyquist freq, times averaged spectra
            sliceHeader.SetSliceLength(fFreqBins*fROACH_FFT_Avg/fFreqMax);

            //bin width = bandwidth/bins
            sliceHeader.SetBinWidth(fFreqMax/fEffectiveFreqBins);

            //assume for now that all runs start at time t=0
            sliceHeader.SetTimeInRun(i/fFreqMax*fFreqBins*fROACH_FFT_Avg);
            KTDEBUG(speclog, "TimeInRun = "<<(i/fFreqMax*fFreqBins*fROACH_FFT_Avg));

            //assume for now that there is 1 acq per run, all runs start at t=0
            sliceHeader.SetTimeInAcq(i/fFreqMax*fFreqBins*fROACH_FFT_Avg);

            sliceHeader.SetStartRecordNumber(0);

            sliceHeader.SetStartSampleNumber(0);

            sliceHeader.SetEndRecordNumber(0);

            sliceHeader.SetEndSampleNumber(0);

            sliceHeader.SetRecordSize(0);


            newSpec[0] = new KTPowerSpectrum(slice, fEffectiveFreqBins, fFreqMin, fFreqMax);
            KTPowerSpectrumData& psData = data->Of< KTPowerSpectrumData >().SetNComponents(1);
            psData.SetSpectrum(newSpec[0], comp);
            psData.GetArray(comp)->GetAxis().SetBinsRange(fFreqMin, fFreqMax, fEffectiveFreqBins);

            if (i == 0)
            {
                KTINFO(speclog, "Set first spectrum object")

                sliceHeader.SetIsNewAcquisition(1);
                KTINFO(speclog, "Set New Acquisition!");

                double min = psData.GetArray(comp)->GetAxis().GetRangeMin();
                KTINFO(speclog, "First spectrum min freq = " << min);

                double max = psData.GetArray(comp)->GetAxis().GetRangeMax();
                KTINFO(speclog, "First spectrum max freq = " << max);

                double width = psData.GetArray(comp)->GetAxis().GetBinWidth();
                KTINFO(speclog, "First spectrum bin width = " << width);
            }
            else sliceHeader.SetIsNewAcquisition(0);

            if(i == fNSpectra -1)
            {
                data->Of< Nymph::KTData >().SetLastData(true);
                KTINFO(speclog, "fLastData set to TRUE");
            }

            fDataSignal(data);
            if (i == 0) KTINFO(speclog, "First spectrum data signal output");
        }

        fSpecDoneSignal();
        KTINFO(speclog, "Spec-done signal output");

        for(unsigned j=0; j<nChannels;++j)
            fSpecs[j].file.close();

        return true;
    }
} /* namespace Katydid */
