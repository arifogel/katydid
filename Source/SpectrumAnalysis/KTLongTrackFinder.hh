/**
 @file KTLongTrackFinder.hh
 @brief Contains KTLongTrackFinder
 @details Finds and creates track from descriminator data
 @Authors: A. Gorman, H.S. Harrington
 @date: March 7, 2024
 */

#ifndef KTLONGTRACKFINDER_HH_
#define KTLONGTRACKFINDER_HH_

#include "KTProcessor.hh"

#include "KTDiscriminatedPoints1DData.hh"
#include "KTDiscriminatedPoint.hh"
#include "KTKDTreeData.hh"

#include "KTMemberVariable.hh"
#include "KTSlot.hh"
#include "KTLongTrackData.hh"

#include <set>


namespace Katydid
{
    class KTEggHeader;
    class KTPowerSpectrum;
    class KTPowerSpectrumData;
    class KTLongTrackData;
    class KTSliceHeader;

    /*!
     Collects points on a linear track

     Configuration name: "long-track-finder"

     Available configuration values:
     - "min-frequency": minimum allowed frequency (has to be set)
     - "max-frequency": max allowed frequency (has to be set)
     - "min-bin": can be set instead of min frequency
     - "max-bin": can be set instead of  max frequency
     - "frequency-acceptance": maximum allowed frequency distance of point to an extrapolated line (in Hz)
     - "time-gap-tolerance": max time gap before track is deemed over.
     - "initial-frequency-acceptance": if the line that a point is being compared to, only has a single point so far, this is the accepted frequency acceptance. Default is frequency_acceptance
     - "initial-time-acceptance": if the line that a point is being compared to, only has a single point so far, this is the accepted time window. Default is time-gap-tolerance
     - "initial-slope": if a line has only one point, this is the line's slope
     - "rel-slope-diff-to-expand" If the relative difference between the local slopes at the previous two time slices was greater than this, double the frequency acceptance. To recover from adding noise or to follow resonance.
     - "n-slope-slices": maximum number of TIME SLICES to include in the slope calculation
     - "min-points": a line only gets converted to a track if it has collected more than this many number of points
     - "max-points": lines will be terminated after this many points. Good for curved tracks/resonances.
     - "min-slope": a line only gets converted to a track if its slope is > than this slope (in Hz/s)

     Slots:
     - "disc-1d": void (KTDataPtr) -- clusters discriminated points to sequential lines candidates
     - "done": void () -- Processes remaining active lines and emits clustering-done signal

     Signals:
     - "long-track-cand": void (KTDataPtr) -- Emitted when a candidate is ready; guarantees KTLongTrackData
     - "clustering-done": void () -- Emitted when track clustering is complete
    */


    class KTLongTrackFinder : public Nymph::KTProcessor
    {
    public:
        /*
        * Function object that sorts points by frequency.
        * This allows us to find points near to existing tracks efficiently.
        */
        struct KTDiscriminedPointFrequencySorter
        {
            bool operator() (const KTDiscriminatedPoints1DData::Point& lhs, const KTDiscriminatedPoints1DData::Point& rhs) const
            {
                return lhs.fAbscissa < rhs.fAbscissa;
            }
        };


        typedef std::set< KTDiscriminatedPoints1DData::Point, KTDiscriminedPointFrequencySorter > STFFrequencySortedPoints;


    public:
        KTLongTrackFinder(const std::string& name = "track-finder");
        virtual ~KTLongTrackFinder();

        bool Configure(const scarab::param_node* node);

        // Parameters for point collection
    MEMBERVARIABLE(double, InitialSlope);
    MEMBERVARIABLE(signed, NSlopeSlices);
    MEMBERVARIABLE(double, FrequencyAcceptance);
    MEMBERVARIABLE(double, InitialFrequencyAcceptance);
    MEMBERVARIABLE(double, InitialTimeAcceptance);
    MEMBERVARIABLE(double, TimeGapTolerance);
    MEMBERVARIABLE(double, RelSlopeDiffToExpand);

        // Parameters for line post-processing
    MEMBERVARIABLE(unsigned, MinPoints);
    MEMBERVARIABLE(unsigned, MaxPoints);
    MEMBERVARIABLE(double, MinSlope);

        // Others
    MEMBERVARIABLE(unsigned, MinBin);
    MEMBERVARIABLE(unsigned, MaxBin);
    MEMBERVARIABLE(bool, CalculateMinBin);
    MEMBERVARIABLE(bool, CalculateMaxBin);
    MEMBERVARIABLE(double, FreqBinWidth);
    MEMBERVARIABLE(double, TimeBinWidth);
    MEMBERVARIABLE(double, MinFrequency);
    MEMBERVARIABLE(double, MaxFrequency);

    // Internal tracking
    MEMBERVARIABLE_PROTECTED(unsigned, NCandidatesEmitted);

    public:
        bool InitializeWithHeader(KTEggHeader& header);

        bool CollectDiscrimPointsFromSlice(KTSliceHeader& slHeader, KTDiscriminatedPoints1DData& discrimPoints);

        void EmitPreCandidate(KTLongTrackData& track);

        void AcquisitionIsOver();

        const std::set< Nymph::KTDataPtr >& GetCandidates() const;

    private:
        // Tracks are implicitly sorted from oldest to newest
        std::list<KTLongTrackData> fActiveLines;
        std::set< Nymph::KTDataPtr > fCandidates;


        //***************
        // Signals
        //***************

    private:
        Nymph::KTSignalData fLineSignal;
        Nymph::KTSignalOneArg< void > fClusterDoneSignal;

        //***************
        // Slots
        //***************

    private:
        Nymph::KTSlotDataOneType< KTEggHeader > fHeaderSlot;
        Nymph::KTSlotDataTwoTypes< KTSliceHeader, KTDiscriminatedPoints1DData > fDiscrimSlot;
        Nymph::KTSlotDone fDoneSlot;

        void HandleFinishedTrack(KTLongTrackData& track);

        bool DoesPointMatchLine(const KTLongTrackData& track, double newTime, double newFrequency) const;

        void AddPointsToExistingTracks(STFFrequencySortedPoints &points, std::list<KTLongTrackData> &tracks, double timeInRunC, double timeInAcqC, int acqID) const;

        std::vector<KTDiscriminatedPoints1DData::Point> GetPointsNearTrack(
                const STFFrequencySortedPoints& sortedPoints, const KTLongTrackData& track, double timeInRunC) const;

        std::list<KTLongTrackData> CreateNewTracks(STFFrequencySortedPoints &points, double timeInRunC, double timeInAcqC, int acqID) const;

        double CalculateLocalSlope(const std::vector<std::pair<double, double>>& points) const;

        static KTLongTrackData::Point CreatePoint(const KTDiscriminatedPoints1DData::Point &point, double timeInRunC, double timeInAcqC, int acqID, double trackFinderSlope) ;
    };
    inline const std::set< Nymph::KTDataPtr >& KTLongTrackFinder::GetCandidates() const
    {
        return fCandidates;
    }

} /* namespace Katydid */
#endif /* KTLONGTRACKFINDER_HH_ */
