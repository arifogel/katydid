#include <iostream>
#include <fstream>
#include <bitset>
#include "KTLongSpecProcessor.hh"
#include "KTCommandLineOption.hh"
#include "KTData.hh"
#include "KTSliceHeader.hh"
#include "KTPowerSpectrum.hh"
#include "KTPowerSpectrumData.hh"

using std::string;
using namespace std;

namespace Katydid
{
    static Nymph::KTCommandLineOption< string > sFilenameCLO("Long Spec Processor",
    "Spec filename to open", "long-spec-file", 'l');

    KTLOGGER(speclog, "KTLongSpecProcessor");

    KT_REGISTER_PROCESSOR(KTLongSpecProcessor, "long-spec-processor");

    KTLongSpecProcessor::KTLongSpecProcessor(const std::string& name) :
            KTPrimaryProcessor(name),
            fProgressReportInterval(1),
            fFilenames(),
            fNSpectra(0),           //the number of spectra we wish to process with the current katydid run
            fFreqBinsPerPkt(8192),  //the number of frequency bins in each UDP packet writtten to *.spec
            fPacketsPerSpectrum(4), //the number of packets needed for the ROACH to output a complete spectrum
            fFreqMin(0.),           //the minimum DAQ frequency
            fFreqMax(1200000000),   //the DAQ Nyquist frequency
            fBinTOff(342),          //the trap off signal frequency bin
            fBinTOffPow(20),
            fROACH_FFT_Avg(2),      //the number of sequential FFTs averaged on the DAQ before output to *.spec
            fSpecTimeAvg(1),        //the number of sequential spectra from *.spec to average with this processor
            fSpecFreqAvg(2),        //the number of freq bins to average (for improving SNR with nonzero df/dt)
            fDataSignal("ps", this),
            fSpecDoneSignal("spec-done", this)
    {
    }

    KTLongSpecProcessor::~KTLongSpecProcessor()
    {
    }

    bool KTLongSpecProcessor::Configure(const scarab::param_node* node)
    {
        // Config-file settings
        if (node != NULL)
        {
            if (node->has("filename"))
            {
                KTDEBUG(speclog, "Adding single file to spec processor");
                fFilenames.clear();
                fFilenames.push_back( std::move(scarab::expand_path(node->get_value( "filename" ))) );
                KTINFO(speclog, "Added file to spec processor: <" << fFilenames.back() << ">");
            }
            else if (node->has("filenames"))
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
            fNSpectra = node->get_value< unsigned >("spectra", fNSpectra);
            KTINFO(speclog, "Number of spectra = " << fNSpectra);
            fPacketsPerSpectrum = node->get_value< unsigned >("packets-per-spec", fPacketsPerSpectrum);
            KTINFO(speclog, "Packets per spectrum = " << fPacketsPerSpectrum);
            fPacketHeaderSize = node->get_value< unsigned >("header-bytes", fPacketHeaderSize);
            fROACH_FFT_Avg = node->get_value< unsigned >("ROACH-spect-avg", fROACH_FFT_Avg);
            fFreqBinsPerPkt = node->get_value< unsigned >("freq-bins-per-packet", fFreqBinsPerPkt);
            fFreqMin = node->get_value< double >("min-freq", fFreqMin);
            fFreqMax = node->get_value< double >("max-freq", fFreqMax);
            fBinTOff = node->get_value< double >("TOff-bin", fBinTOff);
            fBinTOffPow = node->get_value< double >("TOff-bin-pow", fBinTOffPow);
            KTINFO(speclog, "Maximum frequency = " << fFreqMax);
            fSpecTimeAvg = node->get_value< double >("time-slice-avg", fSpecTimeAvg);
            fSpecFreqAvg = node->get_value< double >("freq-bin-avg", fSpecFreqAvg);

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

    bool KTLongSpecProcessor::ProcessSpec()
    {

        if (fFilenames.size() == 0)
        {
            KTERROR(speclog, "No files have been specified");
            return false;
        }

        // open the file and declare a pointer to memory block
        KTINFO(speclog, "Opening spec file <" << fFilenames[0] << ">");
        streampos size;
        unsigned char * memblock;

        std::ifstream file(fFilenames[0].c_str(), ios::in|ios::binary|ios::ate);

        if (file.is_open())
        {
            KTINFO(speclog, "Spec file <" << fFilenames[0] << "> opened");
            unsigned char a;
            //uint a; //spectra must be treated as unsigned 8-bit values (0-255)
            int slice[fPacketsPerSpectrum*fFreqBinsPerPkt/fSpecFreqAvg]; //holder array for spectrum data
            KTINFO(speclog, "Spectrum length = " << fPacketsPerSpectrum*fFreqBinsPerPkt/fSpecFreqAvg);
            int position = 0; //variable for read position start
            int blockSize = fPacketsPerSpectrum*fSpecTimeAvg*(fPacketHeaderSize+fFreqBinsPerPkt); //total bytes
            KTINFO(speclog, "Block size = " << fPacketsPerSpectrum*fSpecTimeAvg*(fPacketHeaderSize+fFreqBinsPerPkt));

            char memblock [blockSize]; //declare array of 1-byte chars to read from binary file
            char headerblock [fPacketHeaderSize]; //declare array to read header of 1st packet in file

            vector <KTPowerSpectrum*> newSpec(1);

            KTINFO(speclog, "Preparing to read first spectrum");

            //The header of each packet is divided into 4 words of 64 bits (8 bytes) each.
            //Information on the packet offset is located in the first 3 bits of the final word.
            //The 0th bit of the last word should always be 1 to indicate freq-domain data.
            //Bits 1 and 2 of the last word indicate which part of the spectrum a packet
            //corresponds to. All trailing bits should be zero.

            char specFlag = 0;

            int packetOffset = 0;

            file.seekg (position, ios::beg); //set read pointer location
            file.read (headerblock, fPacketHeaderSize);

            specFlag = headerblock[24];
            KTINFO(speclog, "Spec flag = " << bitset<8>(specFlag));
            if (bitset<8>(specFlag) == 128) packetOffset = 0;
            else if (bitset<8>(specFlag) == 160) packetOffset = 3 *(fPacketHeaderSize+fFreqBinsPerPkt);
            else if (bitset<8>(specFlag) == 192) packetOffset = 2 *(fPacketHeaderSize+fFreqBinsPerPkt);
            else if (bitset<8>(specFlag) == 224) packetOffset = 1 *(fPacketHeaderSize+fFreqBinsPerPkt);
            else
            {
              packetOffset = 0;
              KTINFO(speclog, "WARNING: Unable to parse packet offset from initial packet header");
            }

            KTINFO(speclog, "Packet Offset = " << packetOffset);

            char specFlagA, specFlagB, specFlagC, specFlagD;

            bool packetDrop =  false;
            vector<int> pkt_num(fNSpectra);

            for(int i = 0; i < fNSpectra; i++) //loop over # of spectra to be output
            {
                unsigned comp = 0;

                //initialize an object of type KTPowerSpectrum with all 0 values
                Nymph::KTDataPtr data(new Nymph::KTData());

                KTSliceHeader& sliceHeader = data->Of< KTSliceHeader >().SetNComponents(1);

                sliceHeader.SetSliceNumber(i);

                //slice size in bytes = # of bins (given 8-bit resolution)
                sliceHeader.SetRawSliceSize(fFreqBinsPerPkt*fPacketsPerSpectrum/fSpecFreqAvg);

                //no diff between 'raw' slice size, slice size
                sliceHeader.SetSliceSize(fFreqBinsPerPkt*fPacketsPerSpectrum/fSpecFreqAvg);

                //Nyquist frequency fFreqMax is 1/2 sampling rate
                sliceHeader.SetSampleRate(2*fFreqMax);

                KTINFO(speclog, "Spectrum time averaging parameter = " << fSpecTimeAvg);
                //slice length (in sec) is 2x # of bins / 2x Nyquist freq, times averaged spectra
                sliceHeader.SetSliceLength(fFreqBinsPerPkt*fPacketsPerSpectrum*fROACH_FFT_Avg*fSpecTimeAvg/fFreqMax);
                KTINFO(speclog, "Setting slice time length to " << fFreqBinsPerPkt*fPacketsPerSpectrum*fROACH_FFT_Avg*fSpecTimeAvg/fFreqMax);

                //bin width = bandwidth/bins
                sliceHeader.SetBinWidth(fFreqMax*fSpecFreqAvg/(fFreqBinsPerPkt*fPacketsPerSpectrum));

                if (i == 0) sliceHeader.SetIsNewAcquisition(1);

                position = packetOffset + i*(blockSize);
                file.seekg (position, ios::beg); //set read pointer location
                file.read (memblock, blockSize); //read 1 time-averaged spectrum of data

                //Check if sequential spectra have correct packet numbers
                pkt_num[i] = bitset<8>(memblock[1]).to_ulong()*pow(2,16)+bitset<8>(memblock[2]).to_ulong()*pow(2,8)+bitset<8>(memblock[3]).to_ulong();
                KTINFO(speclog, "Decimal pkt_num = " << pkt_num[i]);
                if (i>0)
                {
                    int adjusted_pkt_num = (pkt_num[i-1] + fPacketsPerSpectrum*fSpecTimeAvg ) % 1048576; //2^20, max packet number for 2^12 bitcode
                    if(pkt_num[i] - adjusted_pkt_num != 0)
                        KTWARN(speclog, "WARNING: " << pkt_num[i]-adjusted_pkt_num << " packets dropped!");
                }

                specFlagA = memblock[24];
                specFlagB = memblock[8248];
                specFlagC = memblock[16472];
                specFlagD = memblock[24696];

                if ((fPacketsPerSpectrum == 4) && (bitset<8>(specFlagA) != 128 || bitset<8>(specFlagB) != 160
                || bitset<8>(specFlagC) != 192 || bitset<8>(specFlagD) != 224))
                {
                  KTWARN(speclog, "WARNING: Packet dropped from spectrum # " << i << "!!");
                  packetDrop = true;
                  i--;
                  if(bitset<8>(specFlagD) == 128) packetOffset += 3*(fPacketHeaderSize+fFreqBinsPerPkt);
                  else if(bitset<8>(specFlagC) == 128) packetOffset += 2*(fPacketHeaderSize+fFreqBinsPerPkt);
                  else if(bitset<8>(specFlagB) == 128) packetOffset += 1*(fPacketHeaderSize+fFreqBinsPerPkt);
                  else i++;
                }

                else
                {
                  KTINFO(speclog, "Processing spectrum # " << i);
                  if (packetDrop == true)
                  {
                    sliceHeader.SetIsNewAcquisition(1);
                    KTINFO(speclog, "Set New Acquisition!");
                  }
                  else sliceHeader.SetIsNewAcquisition(0);

                  packetDrop = false; //reset packetDrop flag for next spectrum
                  for(int n = 0; n < fSpecTimeAvg; n++)
                  {
                    for(int j = 0; j < fPacketsPerSpectrum; j++)
                    {
                      for (int k = 0; k < fFreqBinsPerPkt/fSpecFreqAvg; k++)
                      {
                        if (n==0) slice[j*fFreqBinsPerPkt/fSpecFreqAvg + k] = 0.0;
                        for (int m = 0; m <fSpecFreqAvg; m++)
                        {
                          //n skips over whole spectra, j skips over packets + headers, k skips over averaged freq bins
                          a =  memblock[n*fPacketsPerSpectrum*(fPacketHeaderSize+fFreqBinsPerPkt)
                                        + j*(fPacketHeaderSize+fFreqBinsPerPkt)+fPacketHeaderSize
                                        + k*fSpecFreqAvg + m];
                          slice[j*fFreqBinsPerPkt/fSpecFreqAvg + k] += a;
                        }
                      }
                    }
                  }
                //KTINFO(speclog, "Power at bin: " << fBinTOff << " : " << slice[fBinTOff]);
                if (slice[fBinTOff] > fBinTOffPow)
                {
                    sliceHeader.SetIsTrapOff(1);
                    //KTINFO(speclog, "Set trap off!");
                }
                else sliceHeader.SetIsTrapOff(0);

                //assume for now that all runs start at time t=0
                sliceHeader.SetTimeInRun(i/fFreqMax*fFreqBinsPerPkt*fPacketsPerSpectrum*fROACH_FFT_Avg*fSpecTimeAvg);

                //assume for now that there is 1 acq per run, all runs start at t=0
                sliceHeader.SetTimeInAcq(i/fFreqMax*fFreqBinsPerPkt*fPacketsPerSpectrum*fROACH_FFT_Avg*fSpecTimeAvg);

                sliceHeader.SetStartRecordNumber(0);

                sliceHeader.SetPacketNumber(pkt_num[i]);

                sliceHeader.SetStartSampleNumber(0);

                sliceHeader.SetEndRecordNumber(0);

                sliceHeader.SetEndSampleNumber(0);

                sliceHeader.SetRecordSize(0);

                newSpec[0] = new KTPowerSpectrum(slice, fPacketsPerSpectrum*fFreqBinsPerPkt/fSpecFreqAvg, fFreqMin, fFreqMax);
                KTPowerSpectrumData& psData = data->Of< KTPowerSpectrumData >().SetNComponents(1);
                psData.SetSpectrum(newSpec[0], comp);
                psData.GetArray(comp)->GetAxis().SetBinsRange(fFreqMin, fFreqMax, fPacketsPerSpectrum*fFreqBinsPerPkt/fSpecFreqAvg);

                double min = psData.GetArray(comp)->GetAxis().GetRangeMin();
                KTINFO(speclog, "Spectrum min freq = " << min);

                double max = psData.GetArray(comp)->GetAxis().GetRangeMax();
                KTINFO(speclog, "Spectrum max freq = " << max);

                double width = psData.GetArray(comp)->GetAxis().GetBinWidth();
                KTINFO(speclog, "Spectrum bin width = " << width);

                KTINFO(speclog, "Set spectrum object");

                if(i == fNSpectra -1)
                {
                    data->Of< Nymph::KTData >().SetLastData(true);
                    KTINFO(speclog, "fLastData set to TRUE");
                }

                fDataSignal(data);
                KTINFO(speclog, "Spectrum data signal output");
                }

            }
            fSpecDoneSignal();
            KTINFO(speclog, "Spec-done signal output");
        }
        file.close();
        return true;
    }
} /* namespace Katydid */
