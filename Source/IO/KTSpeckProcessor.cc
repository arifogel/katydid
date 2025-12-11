#include <iostream>
#include <fstream>
#include "KTSpeckProcessor.hh"
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
    static Nymph::KTCommandLineOption< string > sFilenameCLO("Speck Processor", "Speck filename to open", "speck-file", 'k');

    KTLOGGER(specklog, "KTSpeckProcessor");

    KT_REGISTER_PROCESSOR(KTSpeckProcessor, "speck-processor");

    KTSpeckProcessor::KTSpeckProcessor(const std::string& name) :
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
            fSpecks(),
            fDataSignal("ps", this),
            fSpeckDoneSignal("spec-done", this)
    {
    }

    KTSpeckProcessor::~KTSpeckProcessor()
    {
    }

    bool KTSpeckProcessor::Configure(const scarab::param_node* node)
    {
        // Config-file settings
        if (node != NULL)
        {
            //Priority: filename > filename_i > filenames. Convenient for command-line options
            fFilenames.clear();
            if (node->has("filename"))
            {
                KTDEBUG(specklog, "Adding single file to speck processor");
                fFilenames.push_back( std::move(scarab::expand_path(node->get_value( "filename" ))) );
                KTINFO(specklog, "Added file to speck processor: <" << fFilenames.back() << ">");
            }
            else
            {
                //could generate this list automatically
                std::vector<std::string> tFilenameArgs = {"filenames_0", "filenames_1"};
                for (const auto& filename_arg : tFilenameArgs)
                {
                    if (node->has(filename_arg))
                    {
                        KTDEBUG(specklog, "Adding single file to speck processor");
                        fFilenames.push_back( std::move(scarab::expand_path(node->get_value( filename_arg ))) );
                        KTINFO(specklog, "Added file to speck processor: <" << fFilenames.back() << ">");
                    }
                }
            }

            if ((!fFilenames.size()) && node->has("filenames"))
            {
                KTDEBUG(specklog, "Adding multiple files to speck processor");
                const scarab::param_array* t_filenames = node->array_at("filenames");
                for(scarab::param_array::const_iterator t_file_it = t_filenames->begin(); t_file_it != t_filenames->end(); ++t_file_it)
                {
                    fFilenames.push_back( std::move(scarab::expand_path((*t_file_it)->as_value().as_string())) );
                    KTINFO(specklog, "Added file to speck processor: <" << fFilenames.back() << ">");
                }
            }

            fNSpectra = node->get_value< unsigned >("spectra", fNSpectra);
            fPacketIDOffset = node->get_value< unsigned >("packet-ID-offset", fPacketIDOffset);
            fPacketHeaderSize = node->get_value< unsigned >("header-bytes", fPacketHeaderSize);
            fROACH_FFT_Avg = node->get_value< unsigned >("ROACH-spect-avg", fROACH_FFT_Avg);
            fFreqBins = node->get_value< unsigned >("freq-bins", fFreqBins); //total bins
            fFreqMin = node->get_value< double >("min-freq", fFreqMin);
            fFreqMax = node->get_value< double >("max-freq", fFreqMax);
            fBinTOff = node->get_value< int >("TOff-bin", fBinTOff);
            fBinTOffPow = node->get_value< int >("TOff-bin-pow", fBinTOffPow);
            fSpecFreqAvg = node->get_value< unsigned >("freq-bin-avg", fSpecFreqAvg);
        }

        // Command-line settings
        if (fCLHandler->IsCommandLineOptSet("speck-file"))
        {
            KTDEBUG(specklog, "Adding single file to speck processor from the CL");
            fFilenames.clear();
            fFilenames.push_back( std::move(scarab::expand_path(fCLHandler->GetCommandLineValue< string >("speck-file"))));
            KTINFO(specklog, "Added file to speck processor: <" << fFilenames.back() << ">");
        }

        return true;
    }

    pair<unsigned, unsigned char> KTSpeckProcessor::ReadHighPowerPoint(char *aBuffer)
    {
        // returns (index, power) from byte data in file
        //aIndex (0 - 4095) is a 12-bit number, does not fit in a byte.
        //Fit in 2 bytes via: index = 2^8 a[0] + a[1]

        uint8_t tens = *(aBuffer);
        uint8_t ones = *(aBuffer + 1);
        unsigned index = pow(2,8) * tens + ones;
        char power = *(aBuffer + 2);

        return pair<unsigned, unsigned char>(index, power);

    }

    int KTSpeckProcessor::PacketNumber(char *aBufferPointer)
    {
        int pkt_num = bitset<8>(uint8_t(*(aBufferPointer + fPacketIDOffset))).to_ulong() * pow(2,16);
        pkt_num += bitset<8>(uint8_t(*(aBufferPointer + fPacketIDOffset + 1))).to_ulong() * pow(2,8);
        pkt_num += bitset<8>(uint8_t(*(aBufferPointer + fPacketIDOffset + 2))).to_ulong();
        return pkt_num;
    }

    bool KTSpeckProcessor::ProcessSpeck()
    {
        if (fFilenames.size() == 0)
        {
            KTERROR(specklog, "No files have been specified");
            return false;
        }

        if (fFilenames.size() > 2)
        {
            KTERROR(specklog, "More than 2 speck simultaneous files have been specified! We don't have that much bandwidth!");
            return false;
        }

        //check if fSpecFreqAvg divides fFreqBins evenly
        if(fFreqBins % fSpecFreqAvg != 0)
            KTWARN(specklog, "freq-bin-avg does not divide freq-bins!");

        const unsigned fEffectiveFreqBins = fFreqBins / fSpecFreqAvg;

        const int nChannels = fFilenames.size();
        //check if fFreqBins divides nChannels evenly
        if(fEffectiveFreqBins % nChannels != 0)
            KTWARN(specklog, "nChannels does not divide (effective) freq-bins!");

        // For file j, j*fBinOffsetPerFile is added to the bin numbers to files are not "on top of each other"
        const unsigned fBinOffsetPerFile = fEffectiveFreqBins / nChannels;

        // Open the .speck files
        for(unsigned i = 0; i <fFilenames.size(); ++i)
        {
            KTINFO(specklog, "Opening speck file <" << fFilenames[i] << ">");
            if(fFilenames[i].extension() != ".speck")
                KTFATAL(specklog, fFilenames[i] <<" is not a .speck file!");

            // open the file and load its full contents into memblock
            fSpecks.emplace_back(fFilenames[i]);
            if(!fSpecks[i].file.is_open())
            {
                KTFATAL(specklog, fFilenames[i] <<" is failed to open!");
            }
            else
            {
                KTINFO(specklog, "Speck file <" << fFilenames[i] << "> opened");
            }
        }

        //spectra must be treated as unsigned 8-bit values (0-255)
        int slice[fEffectiveFreqBins]; //holder array for spectrum data, set to all zeros
        std::fill(slice, slice + fEffectiveFreqBins, 0);

        unsigned numHighPowerPoints; //number of above threshold points per slice
        pair<unsigned, unsigned char> highPowerBin; //index, power for above threshold points
        vector<unsigned> nonZeroBins; //store above threshold bins, so that slice can be erased quickly

        vector <KTPowerSpectrum*> newSpec(1);
        vector<int> pkt_num(fNSpectra);
        unsigned binOffset, hpbIndex;

        //loop over # of spectra to be read
        for(int i = 0; i < fNSpectra; ++i)
        {
            if (i == 0) KTINFO(specklog, "Preparing to read first spectrum");

            for(unsigned j = 0; j < nChannels; ++j)
                KTINFO(specklog, "Speck: "<<j<<" is at position: " << fSpecks[j].position);

            pkt_num[i] = PacketNumber(fSpecks[0].pointer);
            KTINFO(specklog, "Decimal pkt_num = " << pkt_num[i]);

            //Check if sequential spectra have correct packet numbers
            if (i>0)
            {
                // Both fPacketsPerSpectrum and fSpecTimeAvg are forced to be 1, for now in speck_processor
                int adjusted_pkt_num = (pkt_num[i-1] + 1) % 1048576; //2^20, max packet number for 2^12 bitcode
                if(pkt_num[i] - adjusted_pkt_num != 0)
                    KTWARN(specklog, "WARNING: " << pkt_num[i]-adjusted_pkt_num << " packets dropped!");
            }
            //Check if simultaneous spectra have correct packet numbers
            if(nChannels == 2  && (pkt_num[i] != PacketNumber(fSpecks[1].pointer)))
                KTFATAL(specklog, "You have packet shear between spectrogram  files! Incompatible files!");

            // advance all speck objects past their headers
            for(unsigned j = 0; j < nChannels; ++j)
                fSpecks[j] += fPacketHeaderSize;

            //reset all output spectrogram bins to zeros
            for(unsigned j = 0; j < nonZeroBins.size(); ++j)
                slice[nonZeroBins[j]] = 0;

            nonZeroBins.clear();

            //loop over sparse points in file, break when reading (0,0) - (end of slice marker)
            numHighPowerPoints = 0;
            for(unsigned j = 0; j < nChannels; ++j)
            { 
                binOffset = j*fBinOffsetPerFile;
                while(fSpecks[j].position < fSpecks[j].nMaxBufferEntry)
                {
                    highPowerBin = ReadHighPowerPoint(fSpecks[j].pointer);
                    fSpecks[j] += 3; //2 bytes for 4096 bin number, 1 byte for power
                    if(highPowerBin.first != 0 || highPowerBin.second !=0)
                    {
                        hpbIndex = highPowerBin.first/fSpecFreqAvg + binOffset;
                        slice[hpbIndex] += highPowerBin.second;
                        numHighPowerPoints += 1;
                        nonZeroBins.push_back(hpbIndex);
                        //KTDEBUG(specklog, "Adding high power point at slice: "<<i<<", bin: "<<hpbIndex<<", power: "<<int(highPowerBin.second));
                    }
                    else
                    {
                        break;
                    }
                }
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
            sliceHeader.SetRawSliceSize(numHighPowerPoints);

            //no diff between 'raw' slice size, slice size
            sliceHeader.SetSliceSize(fFreqBins);

            //Nyquist frequency is 1/2 sampling rate
            sliceHeader.SetSampleRate(2*fFreqMax);
            KTINFO(specklog, "Frequency max = " << fFreqMax);

            //slice length is 2x # of bins / 2x Nyquist freq, times averaged spectra
            sliceHeader.SetSliceLength(fFreqBins*fROACH_FFT_Avg/fFreqMax);

            //bin width = bandwidth/bins
            sliceHeader.SetBinWidth(fFreqMax/fEffectiveFreqBins);

            //assume for now that all runs start at time t=0
            // be super careful about this. The product i*fFreqBins*fROACH_FFT_Avg exceeds the MAX_INT, causing overflow
            // we switch to double be dividing immediately. Could go through intermediate of long ints
            sliceHeader.SetTimeInRun(i/fFreqMax*fFreqBins*fROACH_FFT_Avg);
            KTDEBUG(specklog, "TimeInRun = "<<(i/fFreqMax*fFreqBins*fROACH_FFT_Avg));

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
                KTINFO(specklog, "Set first spectrum object")

                sliceHeader.SetIsNewAcquisition(1);
                KTINFO(specklog, "Set New Acquisition!");

                double min = psData.GetArray(comp)->GetAxis().GetRangeMin();
                KTINFO(specklog, "First spectrum min freq = " << min);

                double max = psData.GetArray(comp)->GetAxis().GetRangeMax();
                KTINFO(specklog, "First spectrum max freq = " << max);

                double width = psData.GetArray(comp)->GetAxis().GetBinWidth();
                KTINFO(specklog, "First spectrum bin width = " << width);
            }
            else sliceHeader.SetIsNewAcquisition(0);

            if(i == fNSpectra -1)
            {
                data->Of< Nymph::KTData >().SetLastData(true);
                KTINFO(specklog, "fLastData set to TRUE");
            }

            fDataSignal(data);
            if (i == 0) KTINFO(specklog, "First spectrum data signal output");
        }

        fSpeckDoneSignal();
        KTINFO(specklog, "Spec-done signal output");

        for(unsigned j=0; j<nChannels;++j)
            fSpecks[j].file.close();

        return true;
    }
} /* namespace Katydid */
