#ifndef KTSPECKPROCESSOR_HH_
#define KTSPECKPROCESSOR_HH_

#include "KTPrimaryProcessor.hh"
#include "KTData.hh"
#include "KTSpecReader.hh"
#include "KTSlot.hh"

namespace Katydid
{

    class KTSpeckHelper
    {
     // Micro-class to organize reading multiple speck files. Includes their buffers and keeps track of their pointers
        public:
            std::ifstream file;
            std::vector<char> buffer;
            unsigned nMaxBufferEntry;
            char *pointer;
            unsigned position;
            KTSpeckHelper() {}
            KTSpeckHelper(boost::filesystem::path aFilename):
             file(aFilename.c_str(), std::ios::in|std::ios::binary),
             buffer(std::istreambuf_iterator<char>(file), {}), //read full (compressed) file into unsigned char vector
             nMaxBufferEntry(buffer.size()),
             pointer(buffer.data()),
             position(0)
            {}
            KTSpeckHelper& operator+=(int aAdvance) { position += aAdvance; pointer += aAdvance; return *this;} //overload += operator to advance buffer pointer
    };

    class KTPowerSpectrumData;

    /*!
     @class KTSpeckProcessor
     @author N. Buzinsky after B. Graner

     @brief reads a file with compress power spectrum data

     Configuration name: "speck-processor"

     Available configuration options:
     - "progress-report-interval": unsigned -- Interval (# of slices) between
        reports (mainly relevant for RELEASE builds); turn off by setting to 0
     - "filename": string -- Speck filename to use
        (will take priority over \"filenames\")
     - "filenames": array of strings -- Speck filenames to use
        (\"filename\" will take priority over this)

     Command-line options defined
     - -k (speck-file): speck filename to use

     Signals:
     - "header": void (Nymph::KTDataPtr) -- emitted when the header is parsed.
     - "psd": void (Nymph::KTDataPtr) -- emitted when the new power spectrum is
        produced; Guarantees KTPowerSpectrumData
     - "spec-done": void () --  emitted when a file is finished.
     - "summary": void (const KTProcSummary*) -- emitted when a file is
        finished (after "spec-done")

    */
    class KTSpeckProcessor : public Nymph::KTPrimaryProcessor
    {
        public:
            KTSpeckProcessor(const std::string& name = "speck-processor");
            virtual ~KTSpeckProcessor();

            bool Configure(const scarab::param_node* node);

            bool Run();

            bool ProcessSpeck();

            MEMBERVARIABLE(unsigned, ProgressReportInterval);

            MEMBERVARIABLEREF(KTSpecReader::path_vec, Filenames);

        private:
            int fNSpectra;
            unsigned fPacketIDOffset; //where in the packet header is the packet ID [1,9], historically
            int fPacketHeaderSize;
            int fFreqBins;
            int fROACH_FFT_Avg;       //the number of sequential FFTs averaged on the DAQ before output to *.spec
            int fSpecFreqAvg;         //the number of freq bins to average (for improving SNR with nonzero df/dt)
            double fFreqMin;
            double fFreqMax;
            int fBinTOff;             //Bin where trap off signal should be found
            int fBinTOffPow;

            Nymph::KTSignalData fDataSignal;
            Nymph::KTSignalOneArg< void > fSpeckDoneSignal;

            std::pair<unsigned, unsigned char> ReadHighPowerPoint(char *aBuffer);
            int PacketNumber(char *aBufferPointer);

            std::vector<KTSpeckHelper> fSpecks;
    };

    inline bool KTSpeckProcessor::Run()
    {
        return ProcessSpeck();
    }

} /* namespace Katydid */

#endif /* KTSPECKPROCESSOR_HH_ */
