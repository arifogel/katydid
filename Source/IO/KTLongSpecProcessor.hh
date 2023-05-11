#ifndef KTEGGPROCESSOR_HH_
#define KTEGGPROCESSOR_HH_

#include "KTPrimaryProcessor.hh"
#include "KTData.hh"
//#include "KTSpecHeader.hh"
#include "KTSpecReader.hh"
#include "KTSlot.hh"

namespace Katydid
{

    class KTPowerSpectrumData;

    /*!
     @class KTLongSpecProcessor
     @author B. Graner + Heather Harrington

     @brief reads a file with power spectrum data

     Configuration name: "spec-processor"

     Available configuration options:
     - "progress-report-interval": unsigned -- Interval (# of slices) between
        reports (mainly relevant for RELEASE builds); turn off by setting to 0
     - "filename": string -- Spec filename to use
        (will take priority over \"filenames\")
     - "filenames": array of strings -- Spec filenames to use
        (\"filename\" will take priority over this)

     Command-line options defined
     - -s (spec-file): spec filename to use

     Signals:
     - "header": void (Nymph::KTDataPtr) -- emitted when the header is parsed.
     - "ps": void (Nymph::KTDataPtr) -- emitted when the new power spectrum is
        produced; Guarantees KTPowerSpectrumData
     - "spec-done": void () --  emitted when a file is finished.
     - "summary": void (const KTProcSummary*) -- emitted when a file is
        finished (after "spec-done")

    */
    class KTLongSpecProcessor : public Nymph::KTPrimaryProcessor
    {
        public:
            KTLongSpecProcessor(const std::string& name = "long-spec-processor");
            virtual ~KTLongSpecProcessor();

            bool Configure(const scarab::param_node* node);

            bool Run();

            bool ProcessSpec();

            MEMBERVARIABLE(unsigned, ProgressReportInterval);

            MEMBERVARIABLEREF(KTSpecReader::path_vec, Filenames);

        private:
            int fNSpectra;
            int fPacketsPerSpectrum;  //the number of packets needed for the ROACH to output a complete spectrum
            int fPacketHeaderSize;    //the size of a DAQ packet header, in bytes
            int fFreqBinsPerPkt;      //the number of frequency bins in each UDP packet writtten to *.spec
            int fROACH_FFT_Avg;       //the number of sequential FFTs averaged on the DAQ before output to *.spec
            int fSpecTimeAvg;         //the number of sequential spectra from *.spec to average with this processor
            int fSpecFreqAvg;         //the number of freq bins to average (for improving SNR with nonzero df/dt)
            double fFreqMin;          //the minimum DAQ frequency
            double fFreqMax;          //the DAQ Nyquist frequency
            int fBinTOff;             //Bin where trap off signal should be found
            int fBinTOffPow;

            Nymph::KTSignalData fDataSignal;
            Nymph::KTSignalOneArg< void > fSpecDoneSignal;


    };

    inline bool KTLongSpecProcessor::Run()
    {
        return ProcessSpec();
    }


} /* namespace Katydid */

#endif /* KTLONGSPECPROCESSOR_HH_ */
