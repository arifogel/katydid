#ifndef KTSPECPROCESSOR_HH_
#define KTSPECPROCESSOR_HH_

#include "KTPrimaryProcessor.hh"
#include "KTData.hh"
#include "KTSpecReader.hh"
#include "KTSlot.hh"

namespace Katydid
{

    class KTSpecHelper
    {
     // Micro-class to organize reading multiple spec files. Includes their buffers and keeps track of their pointers
        public:
            std::ifstream file;
            std::vector<char> buffer;
            char *pointer;
            KTSpecHelper() {}
            KTSpecHelper(boost::filesystem::path aFilename, const unsigned &aBufferSize):
             file(aFilename.c_str(), std::ios::in|std::ios::binary),
             buffer(aBufferSize),
             pointer(buffer.data())
            {}
    };

    class KTPowerSpectrumData;

    /*!
     @class KTSpecProcessor
     @author N. Buzinsky after H. Harrington after B. Graner

     @brief reads a file with compress power spectrum data

     Configuration name: "spec-processor"

     Available configuration options:
     - "progress-report-interval": unsigned -- Interval (# of slices) between
        reports (mainly relevant for RELEASE builds); turn off by setting to 0
     - "filename": string -- Spec filename to use
        (will take priority over \"filenames\")
     - "filenames": array of strings -- Spec filenames to use
        (\"filename\" will take priority over this)

     Command-line options defined
     - -k (spec-file): spec filename to use

     Signals:
     - "header": void (Nymph::KTDataPtr) -- emitted when the header is parsed.
     - "psd": void (Nymph::KTDataPtr) -- emitted when the new power spectrum is
        produced; Guarantees KTPowerSpectrumData
     - "spec-done": void () --  emitted when a file is finished.
     - "summary": void (const KTProcSummary*) -- emitted when a file is
        finished (after "spec-done")

    */
    class KTSpecProcessor : public Nymph::KTPrimaryProcessor
    {
        public:
            KTSpecProcessor(const std::string& name = "spec-processor");
            virtual ~KTSpecProcessor();

            bool Configure(const scarab::param_node* node);

            bool Run();

            bool ProcessSpec();

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
            Nymph::KTSignalOneArg< void > fSpecDoneSignal;

            int PacketNumber(char *aBufferPointer);

            std::vector<KTSpecHelper> fSpecs;
    };

    inline bool KTSpecProcessor::Run()
    {
        return ProcessSpec();
    }

} /* namespace Katydid */

#endif /* KTSPECPROCESSOR_HH_ */
