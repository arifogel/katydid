/**
 @file KTLongTrackFinder.hh
 @brief Contains KTLongTrackFinder
 @details Finds and creates track from descriminator data
 @author: agorman
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
     @class KTSeqTrackFinder
     @author C. Claessens

     @brief Implementation of Dan Furse's algorithm with some modifications

     @details
     Collects points on a linear track

     Configuration name: "sequential-track-finder"

     Available configuration values:
     - "min-frequency": minimum allowed frequency (has to be set)
     - "max-frequency": max allowed frequency (has to be set)
     - "min-bin": can be set instead of min frequency
     - "max-bin": can be set instead of  max frequency
     - "trimming-threshold": before a line is converted to a sparse waterfall candidate its edges get trimmed. If the last or first line point snr is less than the trimming-threshold, they get removed
     - "line-power-radius": only valid for disc1d-ps slot. the power that is assigned to a line point is the sum of the power_spectrum[point_bin - line_width: point_bin + line_width]
     - "time-gap-tolerance": maximum gap between points in a line (in seconds)
     - "minimum-line-distance": requires some thought for disc1d-slot!!! For disc1d-ps slot: if a point is less than this distance (in bins) away from the last point it will be skipped
     - "search-radius": for disc1d-ps slot: before a point is added to a line, the weighted average of the points frequency neighborhood (+/- search-radius in bins) is taken and the point updated until the frequency converges
     - "converge-delta": for disc1d-ps slot: defines when convergence has been reached (in bins)
     - "frequency-acceptance": maximum allowed frequency distance of point to an extrapolated line (in Hz)
     - "slope-method": method to update the line slope after point collection (see options below)
     - "initial-frequency-acceptance": if the line that a point is being compared to, only has a single point so far, this is the accepted frequency acceptance. Default is frequency_acceptance
     - "initial-time-acceptance": if the line that a point is being compared to, only has a single point so far, this is the accepted time window. Default is time-gap-tolerance
     - "initial-slope": if a line has only one point, this is the line's slope
     - "n-slope-points": maximum number of points to include in the slope calculation
     - "min-points": a line only gets converted to a track if it has collected more than this many number of points
     - "max-points": lines will be terminated after this many points. Good for curved tracks/resonances.
     - "min-slope": a line only gets converted to a track if its slope is > than this slope (in Hz/s)
     - "apply-power-cut": default false; if true, the summed-power has to be > total-power-threshold; uses fNeighborhoodAmplitude
     - "apply-point-density-cut": default false; if true, the summed-power/time-length has to be > average-power-threshold; uses fNeighborhoodAmplitude
     - "apply-total-snr-cut": default false; if true, the summed-snr has to be > total-snr-threshold; uses fNeighborhoodAmplitude
     - "apply-average-snr-cut": default false; if true, the summed-snr/time-length has to be > average-snr-threshold; uses fNeighborhoodAmplitude
     - "apply-total-residual-cut: default false; if true, the summed-unitless-residual has to be > total-residual-threshold; uses fNeighborhoodAmplitude
     - "apply-average-residual-cut: default false; if true, the summed-unitless-residual/time-length has to be > average-residual-threshold; uses fNeighborhoodAmplitude
     - "total-power-threshold": threshold for apply-total-power-cut
     - "average-power-threshold": threshold for apply-average-power-cut
     - "total-snr-threshold": threshold for apply-total-snr-cut
     - "average-snr-threshold": threshold for apply-average-snr-cut
     - "total-residual-threshold": threshold for apply-total-residual-cut
     - "average-residual-threshold": threshold for apply-average-residual

     Slots:
     - "disc-1d": void (KTDataPtr) -- clusters discriminated points to sequential lines candidates
     - "disc-1d-ps": void (KTDataPtr) -- clusters discriminated points to sequential line candidates; updates point properties using power spectrum slice
     - "done": void () -- Processes remaining active lines and emits clustering-done signal

     Signals:
     - "seq-cand": void (KTDataPtr) -- Emitted when a candidate is ready; guarantees KTLongTrackData
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
                return lhs.fOrdinate < rhs.fOrdinate;
            }
        };


        typedef std::set< KTDiscriminatedPoints1DData::Point, KTDiscriminedPointFrequencySorter > STFFrequencySortedPoints;


    public:
        KTLongTrackFinder(const std::string& name = "track-finder");
        virtual ~KTLongTrackFinder();

        bool Configure(const scarab::param_node* node);

        // Parameters for point update before adding point to line
    MEMBERVARIABLE(int, SearchRadius);

        // Parameters for point collection
    MEMBERVARIABLE(double, InitialSlope);
    MEMBERVARIABLE(signed, NSlopePoints);
    MEMBERVARIABLE(double, FrequencyAcceptance);
    MEMBERVARIABLE(double, InitialFrequencyAcceptance);
    MEMBERVARIABLE(double, InitialTimeAcceptance);
    MEMBERVARIABLE(double, TimeGapTolerance);

        // Parameters for line post-processing
    MEMBERVARIABLE(double, TrimmingThreshold);
    MEMBERVARIABLE(unsigned, MinPoints);
    MEMBERVARIABLE(unsigned, MaxPoints);
    MEMBERVARIABLE(double, MinSlope);
    MEMBERVARIABLE(double, TotalUnitlessResidualThreshold);
    MEMBERVARIABLE(double, AverageUnitlessResidualThreshold);

        // Others
    MEMBERVARIABLE_PROTECTED(unsigned, NCandidatesEmitted);
    MEMBERVARIABLE(unsigned, MinBin);
    MEMBERVARIABLE(unsigned, MaxBin);
    MEMBERVARIABLE(bool, CalculateMinBin);
    MEMBERVARIABLE(bool, CalculateMaxBin);
    MEMBERVARIABLE(double, FreqBinWidth);
    MEMBERVARIABLE(double, TimeBinWidth);
    MEMBERVARIABLE(double, MinFrequency);
    MEMBERVARIABLE(double, MaxFrequency);

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

        void AddPointsToExistingTracks(STFFrequencySortedPoints &points, std::list<KTLongTrackData> &tracks, double timeInRunC) const;

        std::vector<KTDiscriminatedPoints1DData::Point> GetPointsNearTrack(
                const STFFrequencySortedPoints& sortedPoints, const KTLongTrackData& track, double timeInRunC) const;

        std::list<KTLongTrackData> CreateNewTracks(STFFrequencySortedPoints &points, double timeInRunC) const;

        double CalculateLocalSlope(const std::vector<std::pair<double, double>>& points) const;

        static KTLongTrackData::Point CreatePoint(const KTDiscriminatedPoints1DData::Point &point, double timeInRunC, double trackFinderSlope) ;
    };
    inline const std::set< Nymph::KTDataPtr >& KTLongTrackFinder::GetCandidates() const
    {
        return fCandidates;
    }

} /* namespace Katydid */
#endif /* KTLONGTRACKFINDER_HH_ */
