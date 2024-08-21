/*
 * KTLongTrackFinder.cc
 *
 *  Created on: March 7, 2024
 *      Author: agorman
 */

#include "KTLongTrackFinder.hh"

#include "KTLogger.hh"

#include "KTEggHeader.hh"
#include "KTSliceHeader.hh"
#include "KTPowerSpectrum.hh"
#include "KTSequentialLineData.hh"
#include "KTSparseWaterfallCandidateData.hh"
#include "KTDiscriminatedPoints1DData.hh"

#include <cmath>

using std::vector;


namespace Katydid
{
    KTLOGGER(stflog, "KTLongTrackFinder");

    KT_REGISTER_PROCESSOR(KTLongTrackFinder, "long-track-finder");

    KTLongTrackFinder::KTLongTrackFinder(const std::string& name) :
            KTProcessor(name),
            fTrimmingThreshold(6),
            fTimeGapTolerance(0.0005),
            fFrequencyAcceptance(56166.0528183),
            fInitialFrequencyAcceptance(0.0),
            fInitialTimeAcceptance(0.0),
            fMinPoints(3),
            fMaxPoints(100),
            fMinSlope(0.0),
            fInitialSlope(3.0*pow(10,8)),
            fNSlopePoints(10),
            fMinBin(0),
            fMaxBin(1),
            fFreqBinWidth(0.0),
            fTimeBinWidth(0.0),
            fMinFrequency(0.),
            fMaxFrequency(1.),
            fCalculateMinBin(true),
            fCalculateMaxBin(true),
            fActiveLines(),
            fNCandidatesEmitted(0),
            fLineSignal("seq-cand", this),
            fClusterDoneSignal("clustering-done", this),
            fHeaderSlot("header", this, &KTLongTrackFinder::InitializeWithHeader),
            fDiscrimSlot("disc-1d", this, &KTLongTrackFinder::CollectDiscrimPointsFromSlice),
            fDoneSlot("done", this, &KTLongTrackFinder::AcquisitionIsOver, &fClusterDoneSignal)
    {
    }

    KTLongTrackFinder::~KTLongTrackFinder()
    {
    }

    bool KTLongTrackFinder::Configure(const scarab::param_node* node)
    {
        if (node == NULL) return false;

        SetMinFrequency(node->get_value("min-frequency", GetMinFrequency()));
        SetMaxFrequency(node->get_value("max-frequency", GetMaxFrequency()));

        SetTrimmingThreshold(node->get_value("trimming-threshold", GetTrimmingThreshold()));
        SetMinPoints(node->get_value("min-points", GetMinPoints()));
        SetMaxPoints(node->get_value("max-points", GetMaxPoints()));
        SetMinSlope(node->get_value("min-slope", GetMinSlope()));

        SetTimeGapTolerance(node->get_value("time-gap-tolerance", GetTimeGapTolerance()));
        SetFrequencyAcceptance(node->get_value("frequency-acceptance", GetFrequencyAcceptance()));
        SetInitialSlope(node->get_value("initial-slope", GetInitialSlope()));

        if (node->has("min-bin"))
        {
            SetMinBin(node->get_value< unsigned >("min-bin"));
            SetCalculateMinBin(false);
        }
        if (node->has("max-bin"))
        {
            SetMaxBin(node->get_value< unsigned >("max-bin"));
            SetCalculateMaxBin(false);
        }
        if (node->has("initial-frequency-acceptance"))
        {
            SetInitialFrequencyAcceptance(node->get_value("initial-frequency-acceptance", GetInitialFrequencyAcceptance()));
        }
        else
        {
            SetInitialFrequencyAcceptance(node->get_value("frequency-acceptance", GetInitialFrequencyAcceptance()));
        }
        if (node->has("initial-time-acceptance"))
        {
            SetInitialTimeAcceptance(node->get_value("initial-time-acceptance", GetInitialTimeAcceptance()));
        }
        else
        {
            SetInitialTimeAcceptance(node->get_value("time-gap-tolerance", GetInitialTimeAcceptance()));
        }
        if (node->has("n-slope-points"))
        {
            SetNSlopePoints(node->get_value("n-slope-points", GetNSlopePoints()));
        }

        return true;
    }

    bool KTLongTrackFinder::InitializeWithHeader(KTEggHeader& header)
    {
        fTimeBinWidth = 1. / header.GetAcquisitionRate();
        fFreqBinWidth = 1. / (fTimeBinWidth * header.GetChannelHeader(0)->GetSliceSize());

        return true;
    }

    bool KTLongTrackFinder::CollectDiscrimPointsFromSlice(KTSliceHeader& slHeader, KTDiscriminatedPoints1DData& discrimPoints)
    {
        unsigned minBin = fCalculateMinBin ? fMinFrequency / (double) slHeader.GetBinWidth() : fMinBin;
        unsigned maxBin = fCalculateMaxBin ? fMaxFrequency / (double) slHeader.GetBinWidth() : fMaxBin;

        unsigned nComponents = 1;

        for (unsigned iComponent = 0; iComponent < nComponents; ++iComponent)
        {
            double timeInRunC = slHeader.GetTimeInRun() + 0.5 * slHeader.GetSliceLength();

            STFFrequencySortedPoints points;
            for (auto& point : discrimPoints.GetSetOfPoints(iComponent))
            {
                if (point.first >= minBin and point.first <= maxBin)
                {
                    points.insert(point.second);
                }
            }

            KTDEBUG( stflog, "Collected "<<points.size()<<" points");
//            auto timeInRunC = points.begin()->fAbscissa;

            AddPointsToExistingTracks(points, fActiveLines, timeInRunC);

            for(auto trackIt = fActiveLines.begin(); trackIt != fActiveLines.end();) {
                if(timeInRunC - trackIt->GetPoints().back().Time > fTimeGapTolerance) {
                    HandleFinishedTrack(*trackIt); // let the vector sort itself by earliest track instead of longest track
                    trackIt = fActiveLines.erase(trackIt);
                } else {
                    trackIt++;
                }
            }

            auto newTracks = CreateNewTracks(points, timeInRunC);
            fActiveLines.splice(fActiveLines.end(), newTracks);
        }
        return true;
    }

    std::list<KTLongTrackData> KTLongTrackFinder::CreateNewTracks(STFFrequencySortedPoints& points, double timeInRunC) const {
        auto newTracks = std::list<KTLongTrackData>();

        // TODO: Pick out best point from cluster, like we do when adding to existing tracks
        for(auto pointIt = points.begin(); pointIt != points.end(); pointIt = points.erase(pointIt)) {
            KTLongTrackData newLine;
            newLine.AddPoint(CreatePoint(*pointIt, timeInRunC, fInitialSlope));
            newTracks.push_back(newLine);
        }

        if(!newTracks.empty() ) { KTWARN(stflog, "Starting "<< newTracks.size() << " new tracks") }

        return newTracks;
    }

    void KTLongTrackFinder::AddPointsToExistingTracks(
            STFFrequencySortedPoints& points,
            std::list<KTLongTrackData>& tracks,
            double timeInRunC) const {
        for (auto& track : tracks) {
            if(points.empty()) { break; }  // Break early when we run out of points

            std::vector<KTDiscriminatedPoints1DData::Point> matchingPoints = GetPointsNearTrack(points, track, timeInRunC);

            if(!matchingPoints.empty()) {
                auto bestPoint = std::max_element(matchingPoints.begin(), matchingPoints.end(),
                                                  [](auto a, auto b) { return a.fOrdinate > b.fOrdinate; });
                auto slopeCalcPoints = std::vector<std::pair<double,double>>();
                std::transform(track.GetPoints().end() - std::min(4, (int) track.GetPoints().size()),
                          track.GetPoints().end(),
                          std::back_inserter(slopeCalcPoints),
                          [] (auto& p) { return std::pair<double,double>(p.Time, p.Frequency); });
                slopeCalcPoints.emplace_back(timeInRunC, bestPoint->fOrdinate);

                auto localSlope = CalculateLocalSlope(slopeCalcPoints);
                track.AddPoint(CreatePoint(*bestPoint, timeInRunC, localSlope));

                // Consume all points that were near the track, even if we didn't select them. This is because tracks are
                // assumed to be spaced quite far apart, so it's just easier to use a more naive algorithm here.
                for (auto& matchingPoint : matchingPoints) { points.erase(matchingPoint); }
            }
        }
    }



    std::vector<KTDiscriminatedPoints1DData::Point> KTLongTrackFinder::GetPointsNearTrack(
            const STFFrequencySortedPoints& sortedPoints, const KTLongTrackData& track, double timeInRunC) const {

        // do some cool binary search or whatever to speed things up.
        // This will just look at every point until we find the first matching point
        std::vector<KTDiscriminatedPoints1DData::Point> pointsToConsider;
        for (auto& point : sortedPoints) {
            if(DoesPointMatchLine(track, timeInRunC, point.fAbscissa)) {
                pointsToConsider.push_back(point);
            }
            // Once we start missing points, break since we won't find any ever again
        }

        return pointsToConsider;
    }


    bool KTLongTrackFinder::DoesPointMatchLine(const KTLongTrackData& track, double newTime, double newFrequency) const {
        auto trackPoints = track.GetPoints();

        double deltaTime = newTime - trackPoints.back().Time;

        // Frequency we would expect a point matching this track to be at
        double predictedFrequency = trackPoints.back().Frequency + trackPoints.back().TrackFinderLocalSlope * deltaTime;
        // Difference between predicted frequency for this track and the observed frequency of this point
        double predictedActualFrequencyDelta = std::abs(newFrequency - predictedFrequency);

        if(trackPoints.size() == 1 and predictedActualFrequencyDelta < fInitialFrequencyAcceptance and deltaTime < fInitialTimeAcceptance) {
            return true;
        } else if(predictedActualFrequencyDelta < fFrequencyAcceptance) {
            return true;
        }

        return false;
    }

    void KTLongTrackFinder::HandleFinishedTrack(KTLongTrackData& track) {
        if (track.GetPoints().size() >= fMinPoints)
        {
//            track.LineSNRTrimming(fTrimmingThreshold, fMinPoints);

            if (track.GetPoints().size() >= fMinPoints and track.GetBulkSlope() >= fMinSlope)
            {
                KTDEBUG(stflog, "Found line candidate");
//                track.SetSlope(CalculateLocalSlope(track));
                EmitPreCandidate(track);
            }
        }
    }

    void KTLongTrackFinder::EmitPreCandidate(KTLongTrackData& track)
    {
        KTDEBUG(stflog, "applying cuts and then emitting candidate");
//        track.CalculateTotalPower();
//        track.CalculateTotalSNR();
//        track.CalculateTotalNUP();


        // Set up new data object
        Nymph::KTDataPtr data(new Nymph::KTData());
        auto& newCand = data->Of<KTLongTrackData>();
        newCand.TrackId = fNCandidatesEmitted;
        newCand.SetPoints(track.GetPoints());

        ++fNCandidatesEmitted;

        KTDEBUG(stflog, "Emitting track signal");
        fCandidates.insert(data);
        fLineSignal(data);
    }

    void KTLongTrackFinder::AcquisitionIsOver()
    {
        KTINFO(stflog, "Got egg-done signal. Checking remaining line candidates");

        auto lineIt = fActiveLines.begin();
        while( lineIt != fActiveLines.end())
        {
            if (lineIt->GetPoints().size() >= fMinPoints)
            {
                if (lineIt->GetPoints().size() <= fMaxPoints)
                {
//                    TODO ALEX:
//                    lineIt->LineSNRTrimming(fTrimmingThreshold, fMinPoints);

                    if (lineIt->GetPoints().size() >= fMinPoints and lineIt->GetBulkSlope() > fMinSlope and lineIt->GetPoints().size() <= fMaxPoints)
                    {
                        EmitPreCandidate(*lineIt);
                    }
                }
            }

            lineIt = fActiveLines.erase(lineIt);
        }
        KTDEBUG(stflog, "Now there should be no lines left over " << fActiveLines.empty());
    }

    /*
     * Calculates the slope of the end of the track using least squares.
     * Takes a vector of (time,frequency) pairs, ordered by time, oldest to most recent
     */
    double KTLongTrackFinder::CalculateLocalSlope(const std::vector<std::pair<double, double>>& points) const {
        if(points.size() == 1) {
            return fInitialSlope;
        }

        int maxPoints = std::min((int) points.size(), 5);

        auto&& pointIt = points.rbegin();
        double sumX = 0, sumY = 0, sumXY = 0, sumXX = 0;
        for (int i = 0; i < maxPoints; i++) {
            sumX += pointIt->first;
            sumY += pointIt->second;
            sumXY += pointIt->first * pointIt->second;
            sumXX += pointIt->first * pointIt->first;
            pointIt++;
        }

        return (maxPoints * sumXY - sumX * sumY)/(sumXX * maxPoints - sumX * sumX);
    }

    KTLongTrackData::Point KTLongTrackFinder::CreatePoint(
            const KTDiscriminatedPoints1DData::Point &point, double timeInRunC, double trackFinderSlope) {
        return {
                timeInRunC,
                point.fAbscissa,
                point.fOrdinate,
                point.fThreshold,
                1, //TODO SNR
                point.fMean,
                point.fVariance,
                trackFinderSlope};
    }

} /* namespace Katydid */
