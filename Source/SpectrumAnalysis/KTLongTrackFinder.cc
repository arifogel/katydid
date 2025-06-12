/*
 * KTLongTrackFinder.cc
 *
 *  Created on: March 7, 2024
 *  Authors: A. Gorman, H.S. Harrington
 */

#include "KTLongTrackFinder.hh"

#include "KTLogger.hh"

#include "KTEggHeader.hh"
#include "KTSliceHeader.hh"
#include "KTDiscriminatedPoints1DData.hh"

#include <cmath>

using std::vector;


namespace Katydid
{
    KTLOGGER(stflog, "KTLongTrackFinder");

    KT_REGISTER_PROCESSOR(KTLongTrackFinder, "long-track-finder");

    KTLongTrackFinder::KTLongTrackFinder(const std::string& name) :
            KTProcessor(name),
            fTimeGapTolerance(0.0005),
            fFrequencyAcceptance(56166.0528183),
            fInitialFrequencyAcceptance(0.0),
            fInitialTimeAcceptance(0.0),
            fMinPoints(3),
            fMaxPoints(1e8),
            fMinSlope(0.0),
            fInitialSlope(3.0*pow(10,8)),
            fNSlopePoints(5),
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
            fLineSignal("long-track-cand", this),
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

        fFreqBinWidth = slHeader.GetBinWidth();
        fTimeBinWidth = slHeader.GetSliceLength();
        KTDEBUG( stflog, "fTimeBinWidth "<<fTimeBinWidth<<" fFreqBinWidth "<<fFreqBinWidth);


        unsigned nComponents = 1;

        for (unsigned iComponent = 0; iComponent < nComponents; ++iComponent)
        {
            double timeInRunC = slHeader.GetTimeInRun() + 0.5 * slHeader.GetSliceLength();
            double timeInAcqC = slHeader.GetTimeInAcq() + 0.5 * slHeader.GetSliceLength();
            int acqID = slHeader.GetAcquisitionID();

            STFFrequencySortedPoints points;
            for (auto& point : discrimPoints.GetSetOfPoints(iComponent))
            {
                KTDEBUG( stflog, "Min Bin "<<minBin<<" Max Bin "<<maxBin<<" Point bin: "<<point.first);
                if (point.first >= minBin and point.first <= maxBin)
                {
                    points.insert(point.second);
                }
            }

            KTDEBUG( stflog, "Collected "<<points.size()<<" points");

            AddPointsToExistingTracks(points, fActiveLines, timeInRunC, timeInAcqC, acqID);

            for(auto trackIt = fActiveLines.begin(); trackIt != fActiveLines.end();) {
                if(timeInRunC - trackIt->GetPoints().back().TimeInRunC > fTimeGapTolerance or trackIt->GetPoints().size() >= fMaxPoints) {
                    KTDEBUG(stflog, "trackIt->GetPoints().back().TimeInRunC "<<trackIt->GetPoints().back().TimeInRunC);
                    HandleFinishedTrack(*trackIt); // let the vector sort itself by earliest track instead of longest track
                    trackIt = fActiveLines.erase(trackIt);
                } else {
                    trackIt++;
                }
            }

            auto newTracks = CreateNewTracks(points, timeInRunC, timeInAcqC, acqID);
            fActiveLines.splice(fActiveLines.end(), newTracks);
        }
        return true;
    }

    std::list<KTLongTrackData> KTLongTrackFinder::CreateNewTracks(STFFrequencySortedPoints& points, double timeInRunC, double timeInAcqC, int acqID) const {
        auto newTracks = std::list<KTLongTrackData>();

        // TODO: Pick out best point from cluster, like we do when adding to existing tracks. For now, all non-claimed points.
        for(auto pointIt = points.begin(); pointIt != points.end(); pointIt = points.erase(pointIt)) {
            KTLongTrackData newLine;
            newLine.AddPoint(CreatePoint(*pointIt, timeInRunC, timeInAcqC, acqID, fInitialSlope));
            newTracks.push_back(newLine);
        }

        if(!newTracks.empty() ) { KTWARN(stflog, "Starting "<< newTracks.size() << " new tracks") }

        return newTracks;
    }

    void KTLongTrackFinder::AddPointsToExistingTracks(
            STFFrequencySortedPoints& points,
            std::list<KTLongTrackData>& tracks,
            double timeInRunC, double timeInAcqC, int acqID) const {
        for (auto& track : tracks) {
            if(points.empty()) { break; }  // Break early when we run out of points
                //KTDEBUG(stflog, "Checking for matched for track with track.GetPoints().size() "<<track.GetPoints().size());
            std::vector<KTDiscriminatedPoints1DData::Point> matchingPoints = GetPointsNearTrack(points, track, timeInRunC);
            if(matchingPoints.size()>0){
                KTDEBUG(stflog, "Number of matching points: " << matchingPoints.size());
            }
            

            if(!matchingPoints.empty()) {
                for (const auto& p : matchingPoints) {
                    KTDEBUG(stflog, "Frequency: " << p.fAbscissa << ", Power: " << p.fOrdinate<< ", Tau: " << p.fTau<< ", SNR: " << p.fOrdinate/p.fTau);
                }
                //bestPoint is the consumed point at this time slice with the higherst SNR. This is taken as the "frequency". 
                //Could do a fit or take middle instead.
                auto bestPoint = std::max_element(matchingPoints.begin(), matchingPoints.end(),
                                                  [](auto a, auto b) { return a.fOrdinate/a.fTau < b.fOrdinate/b.fTau; });
                auto slopeCalcPoints = std::vector<std::pair<double,double>>();
                std::transform(track.GetPoints().end() - std::min(fNSlopePoints, (int) track.GetPoints().size()),
                          track.GetPoints().end(),
                          std::back_inserter(slopeCalcPoints),
                          [] (auto& p) { return std::pair<double,double>(p.TimeInRunC, p.Frequency); });
                slopeCalcPoints.emplace_back(timeInRunC, bestPoint->fAbscissa);

                auto localSlope = CalculateLocalSlope(slopeCalcPoints);
                //track.AddPoint(CreatePoint(*bestPoint, timeInRunC, localSlope));
                
                // Consume all points that were near the track, even if we didn't select them. This is because tracks are
                // assumed to be spaced quite far apart, so it's just easier to use a more naive algorithm here.
                for (auto& matchingPoint : matchingPoints) {
                    track.AddPoint(CreatePoint(matchingPoint, timeInRunC, timeInAcqC, acqID, localSlope));
                    points.erase(matchingPoint); 
                }
                if(matchingPoints.size()>0){
                    KTDEBUG(stflog, "Number of points left in slice after adding those to track: " << points.size());
                }
                

                // Throw out all other points that were near the track, even if we didn't select them. This is because tracks are
                // assumed to be spaced quite far apart, so it's just easier to use a more naive algorithm here.
                //for (auto& matchingPoint : matchingPoints) { points.erase(matchingPoint); }

            }
        }
    }



    std::vector<KTDiscriminatedPoints1DData::Point> KTLongTrackFinder::GetPointsNearTrack(
            const STFFrequencySortedPoints& sortedPoints, const KTLongTrackData& track, double timeInRunC) const {

        // We can do some cool binary search or whatever to speed things up.
        // This will just look at every point to find matching points
        std::vector<KTDiscriminatedPoints1DData::Point> pointsToConsider;
        for (auto& point : sortedPoints) {
            if(DoesPointMatchLine(track, timeInRunC, point.fAbscissa)) {
                pointsToConsider.push_back(point);
                KTDEBUG(stflog, "Added point to line!");
            } 
        }

        return pointsToConsider;
    }


    bool KTLongTrackFinder::DoesPointMatchLine(const KTLongTrackData& track, double newTime, double newFrequency) const {
        auto trackPoints = track.GetPoints();

        double deltaTime = newTime - trackPoints.back().TimeInRunC;

        // Frequency we would expect a point matching this track to be at
        double predictedFrequency = trackPoints.back().Frequency + trackPoints.back().TrackFinderLocalSlope * deltaTime;
        //KTDEBUG(stflog, "predicted Frequency: " << predictedFrequency<<", newFrequency: "<<newFrequency);
        // Difference between predicted frequency for this track and the observed frequency of this point
        double predictedActualFrequencyDelta = std::abs(newFrequency - predictedFrequency);
        
        /*
        if(trackPoints.size() == 1 and predictedActualFrequencyDelta < fInitialFrequencyAcceptance and deltaTime < fInitialTimeAcceptance) {
            KTINFO(stflog, "second point to a track! fInitialFrequencyAcceptance: "<<fInitialFrequencyAcceptance<<" fInitialTimeAcceptance: "<<fInitialTimeAcceptance<<" predictedActualFrequencyDelta: " << predictedActualFrequencyDelta);
            return true;
        } else if(predictedActualFrequencyDelta < fFrequencyAcceptance) {
            KTWARN(stflog, "Subsiquent points to a track! fFrequencyAcceptance: "<<fFrequencyAcceptance<<" predictedActualFrequencyDelta: "<<predictedActualFrequencyDelta);
            return true;
        }
        */
        if(predictedActualFrequencyDelta < fFrequencyAcceptance) {
            KTDEBUG(stflog, "Subsiquent points to a track! fFrequencyAcceptance: "<<fFrequencyAcceptance<<" predictedActualFrequencyDelta: "<<predictedActualFrequencyDelta);
            return true;
        }

        return false;
    }

    void KTLongTrackFinder::HandleFinishedTrack(KTLongTrackData& track) {
        if (track.GetPoints().size() >= fMinPoints and track.GetBulkSlope() >= fMinSlope) {
            KTWARN(stflog, "Found line candidate");
            EmitPreCandidate(track);
        }
    }

    void KTLongTrackFinder::EmitPreCandidate(KTLongTrackData& track)
    {
        KTDEBUG(stflog, "emitting candidate");
        KTDEBUG(stflog, "emitting candidate with " << track.GetPoints().size() << " points");

        // Set up new data object
        Nymph::KTDataPtr data(new Nymph::KTData());
        auto& newCand = data->Of<KTLongTrackData>();
        newCand.TrackId = fNCandidatesEmitted;
        newCand.SetPoints(track.GetPoints());
        // Compute and store track stats
        newCand.CalculateTrackStats(fTimeBinWidth,fFreqBinWidth);

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
            if (lineIt->GetPoints().size() >= fMinPoints and lineIt->GetPoints().size() <= fMaxPoints
                and lineIt->GetBulkSlope() > fMinSlope) {
                EmitPreCandidate(*lineIt);
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
        for (const auto& p : points) {
            KTDEBUG(stflog, "Time: " << p.first << ", Frequency: " << p.second);
        }
        if(points.size() == 1) {
            return fInitialSlope;
        }

        //int maxPoints = std::min((int) points.size(), 5);
        int maxPoints = (int) points.size();

        auto&& pointIt = points.begin(); //DONT want to do this in reverse!
        double sumX = 0, sumY = 0, sumXY = 0, sumXX = 0;
        for (int i = 0; i < maxPoints; i++) {
            sumX += pointIt->first;
            sumY += pointIt->second;
            sumXY += pointIt->first * pointIt->second;
            sumXX += pointIt->first * pointIt->first;
            pointIt++;
        }
        KTDEBUG(stflog, "CalcLocalSlope: " << (maxPoints * sumXY - sumX * sumY)/(sumXX * maxPoints - sumX * sumX));
        return (maxPoints * sumXY - sumX * sumY)/(sumXX * maxPoints - sumX * sumX);
    }

    KTLongTrackData::Point KTLongTrackFinder::CreatePoint(
            const KTDiscriminatedPoints1DData::Point &point, double timeInRunC, double timeInAcqC, int acqID, double trackFinderSlope) {
        return {
                timeInRunC,
                timeInAcqC,
                acqID,
                point.fAbscissa,
                point.fOrdinate,
                point.fThreshold,
                point.fOrdinate / point.fTau,
                point.fMean,
                point.fTau,
                point.fVariance,
                trackFinderSlope};
    }

} /* namespace Katydid */
