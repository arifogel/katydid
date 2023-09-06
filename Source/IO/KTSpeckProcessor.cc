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
            fFreqBins(4096),
            fNSpectra(0),
            fFreqMin(0.),
            fFreqMax(1600000000),
            fBinTOff(342),          //the trap off signal frequency bin
            fBinTOffPow(20),
            fSpectraAvg(2),
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
            if (node->has("filename"))
            {
                KTDEBUG(specklog, "Adding single file to speck processor");
                fFilenames.clear();
                fFilenames.push_back( std::move(scarab::expand_path(node->get_value( "filename" ))) );
                KTINFO(specklog, "Added file to speck processor: <" << fFilenames.back() << ">");
            }
            else if (node->has("filenames"))
            {
                KTDEBUG(specklog, "Adding multiple files to speck processor");
                fFilenames.clear();
                const scarab::param_array* t_filenames = node->array_at("filenames");
                for(scarab::param_array::const_iterator t_file_it = t_filenames->begin(); t_file_it != t_filenames->end(); ++t_file_it)
                {
                    fFilenames.push_back( std::move(scarab::expand_path((*t_file_it)->as_value().as_string())) );
                    KTINFO(specklog, "Added file to speck processor: <" << fFilenames.back() << ">");
                }
            }

            fNSpectra = node->get_value< unsigned >("spectra", fNSpectra);
            fPacketHeaderSize = node->get_value< unsigned >("header-bytes", fPacketHeaderSize);
            fSpectraAvg = node->get_value< unsigned >("ROACH-spect-avg", fSpectraAvg);
            fFreqBins = node->get_value< unsigned >("freq-bins", fFreqBins);
            fFreqMin = node->get_value< double >("min-freq", fFreqMin);
            fFreqMax = node->get_value< double >("max-freq", fFreqMax);
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
    pair<unsigned, unsigned char> KTSpeckProcessor::read_high_power_point(char *aBuffer)
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

    bool KTSpeckProcessor::ProcessSpeck()
    {
        if (fFilenames.size() == 0)
        {
            KTERROR(specklog, "No files have been specified");
            return false;
        }

        // open the file and load its contents into memblock
        KTINFO(specklog, "Opening speck file <" << fFilenames[0] << ">");

        std::ifstream file(fFilenames[0].c_str(), ios::in|ios::binary);

        if (file.is_open())
        {
            KTINFO(specklog, "Speck file <" << fFilenames[0] << "> opened");
            vector<char> buffer(std::istreambuf_iterator<char>(file), {}); //read full (compressed) file into unsigned char vector
            unsigned nMaxBufferEntry = buffer.size();

            //spectra must be treated as unsigned 8-bit values (0-255)
            int slice[fFreqBins]; //holder array for spectrum data, set to all zeros
            memset(slice, 0, fFreqBins);

            int position = 0; //variable for read position start
            unsigned numHighPowerPoints; //number of above threshold points per slice
            pair<unsigned, unsigned char> highPowerBin; //index, power for above threshold points
            vector<unsigned> nonZeroBins; //store above threshold bins, so that slice can be erased quickly

            vector <KTPowerSpectrum*> newSpec(1);
            int pkt_num [fNSpectra];

            //loop over # of spectra to be read
            for(int i = 0; i < fNSpectra; i++)
            {
                if (i == 0) KTINFO(specklog, "Preparing to read first spectrum");
                KTINFO(specklog, "position = " << position);

                //Check if sequential spectra have correct packet numbers
                pkt_num[i] = bitset<8>(uint8_t(buffer[position + 1])).to_ulong()*pow(2,16);
                pkt_num[i] += bitset<8>(uint8_t(buffer[position + 2])).to_ulong()*pow(2,8);
                pkt_num[i] += bitset<8>(uint8_t(buffer[position + 3])).to_ulong();
                KTINFO(specklog, "Decimal pkt_num = " << pkt_num[i]);
                if (i>0 && pkt_num[i]-pkt_num[i-1]!=1){
                    KTWARN(specklog, "WARNING: " << pkt_num[i]-pkt_num[i-1] << " packets dropped!");
                }

                position += fPacketHeaderSize;

                //reset all output spectrogram bins to zeros
                for(unsigned j = 0; j < nonZeroBins.size(); ++j)
                    slice[nonZeroBins[j]] = 0;

                nonZeroBins.clear();

                //loop over sparse points in file, break when reading (0,0) - (end of slice marker)
                numHighPowerPoints = 0;
                while(position < nMaxBufferEntry)
                {
                    highPowerBin = read_high_power_point(buffer.data() + position);
                    position += 3; //2 bytes for 4096 bin number, 1 byte for power
                    if(highPowerBin.first != 0 && highPowerBin.second !=0)
                    {
                        slice[highPowerBin.first] = highPowerBin.second;
                        numHighPowerPoints += 1;
                        nonZeroBins.push_back(highPowerBin.first);
                        KTDEBUG(specklog, "Adding high power point at slice: "<<i<<", bin: "<<highPowerBin.first<<", power: "<<int(highPowerBin.second));
                        //std::cout<<"Adding high power point at slice: "<<i<<", bin: "<<highPowerBin.first<<", power: "<<int(highPowerBin.second)<<std::endl;
                    }
                    else
                    {
                        break;
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
                sliceHeader.SetSliceLength(fFreqBins*fSpectraAvg/fFreqMax);

                //bin width = bandwidth/bins
                sliceHeader.SetBinWidth(fFreqMax/fFreqBins);

                //assume for now that all runs start at time t=0
                sliceHeader.SetTimeInRun(i*fFreqBins*fSpectraAvg/fFreqMax);
                KTDEBUG(specklog, "TimeInRun = "<<(i*fFreqBins*fSpectraAvg/fFreqMax));

                //assume for now that there is 1 acq per run, all runs start at t=0
                sliceHeader.SetTimeInAcq(i*fFreqBins*fSpectraAvg/fFreqMax);

                sliceHeader.SetStartRecordNumber(0);

                sliceHeader.SetStartSampleNumber(0);

                sliceHeader.SetEndRecordNumber(0);

                sliceHeader.SetEndSampleNumber(0);

                sliceHeader.SetRecordSize(0);


                newSpec[0] = new KTPowerSpectrum(slice, fFreqBins, fFreqMin, fFreqMax);
                KTPowerSpectrumData& psData = data->Of< KTPowerSpectrumData >().SetNComponents(1);
                psData.SetSpectrum(newSpec[0], comp);
                psData.GetArray(comp)->GetAxis().SetBinsRange(fFreqMin, fFreqMax, fFreqBins);

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
        }
        file.close();
        return true;
    }
} /* namespace Katydid */
