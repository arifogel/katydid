#ifndef KTEGGPROCESSOR_HH_
#define KTEGGPROCESSOR_HH_

#include "KTPrimaryProcessor.hh"
#include "KTData.hh"
#include "KTSpecReader.hh"
#include "KTSlot.hh"

namespace Katydid
{

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
            int fPacketHeaderSize;
            int fSpectraAvg;
            int fFreqBins;
            double fFreqMin;
            double fFreqMax;

            Nymph::KTSignalData fDataSignal;
            Nymph::KTSignalOneArg< void > fSpeckDoneSignal;

            std::pair<unsigned, char> read_high_power_point(char *aBuffer);


    };

    inline bool KTSpeckProcessor::Run()
    {
        return ProcessSpeck();
    }



} /* namespace Katydid */

#endif /* KTSPECPROCESSOR_HH_ */
