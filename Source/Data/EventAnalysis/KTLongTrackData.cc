/**
 @file KTLongTrackData.cc
 @brief Contains KTLongTrackData
 @details KTDiscriminatedPoint cluster with some track properties
 @Authors: A. Gorman, H.S. Harrington
 @date: March 7, 2024
 */
#include <KTLongTrackData.hh>
#include "KTSliceHeader.hh"
#include "KTLogger.hh"

#include <iostream>
#include <cmath>
#include <algorithm>

namespace Katydid
{
    const std::string KTLongTrackData::sName("long-track");
	KTLOGGER(seqlog, "KTLongTrack");

    KTLongTrackData::KTLongTrackData():
        TrackId()
        {}

    KTLongTrackData::~KTLongTrackData() = default;


    void KTLongTrackData::AddPoint(const KTLongTrackData::Point &point) {
        points.push_back(point);
    }

    // Copies vector of points to internal points vector
    void KTLongTrackData::SetPoints(const std::vector<KTLongTrackData::Point> &pointsToCopy) {
        points = pointsToCopy;

        // Sort by TimeInRunC ascending, and then by Frequency ascending if times are equal
        auto timeFreqSorter = [] (const auto& first, const auto& second) {
            if (first.TimeInRunC != second.TimeInRunC) {
                return first.TimeInRunC < second.TimeInRunC;
            }
            return first.Frequency < second.Frequency;
        };

        if (!std::is_sorted(points.begin(), points.end(), timeFreqSorter)) {
            std::stable_sort(points.begin(), points.end(), timeFreqSorter);
        }
    }

    double KTLongTrackData::GetBulkSlope() const {
        if (points.size() < 2) return 0.0;

        double sumX = 0.0;   // Time
        double sumY = 0.0;   // Frequency
        double sumXY = 0.0;
        double sumXX = 0.0;
        size_t n = points.size();

        for (const auto& point : points) {
            double x = point.TimeInRunC;
            double y = point.Frequency;

            sumX += x;
            sumY += y;
            sumXY += x * y;
            sumXX += x * x;
        }

        double numerator = n * sumXY - sumX * sumY;
        double denominator = n * sumXX - sumX * sumX;

        return (denominator != 0.0) ? numerator / denominator : 0.0;
    }

    double KTLongTrackData::ComputeAcqFreqIntercept() const {
        if (points.size() < 2) return 0.0;

        const double slope = GetBulkSlope();
        const double acqTime0 = points.front().TimeInAcqC;
        const double freq0 = points.front().Frequency;

        return freq0 - slope * acqTime0;
    }

    void KTLongTrackData::ComputeLocalSlopeStats(TrackStats& stats) const {
        std::vector<double> slopes;
        for (const auto& pt : points) {
            slopes.push_back(pt.TrackFinderLocalSlope);
        }

        ComputeBasicStats(slopes,
                          stats.MeanLocalSlope,
                          stats.StdDevLocalSlope,
                          stats.MinLocalSlope,
                          stats.MaxLocalSlope);
    }

    void KTLongTrackData::ComputeSnrStats(TrackStats& stats) const {
        std::vector<double> snrs;
        stats.TotalSnr = 0.0;
        for (const auto& pt : points) {
            snrs.push_back(pt.SNR);
            stats.TotalSnr += pt.SNR;
        }

        ComputeBasicStats(snrs,
                          stats.MeanSnr,
                          stats.StdDevSnr,
                          stats.MinSnr,
                          stats.MaxSnr);
    }

    void KTLongTrackData::ComputePowerStats(TrackStats& stats) const {
        std::vector<double> powers;
        stats.TotalPower = 0.0;
        for (const auto& pt : points) {
            double power = pt.Ordinate * pt.Ordinate;
            powers.push_back(power);
            stats.TotalPower += power;
        }

        ComputeBasicStats(powers,
                          stats.MeanPower,
                          stats.StdDevPower,
                          stats.MinPower,
                          stats.MaxPower);
    }


    const KTLongTrackData::TrackStats& KTLongTrackData::CalculateTrackStats(double fTimeBinWidth,double fFreqBinWidth)
    {
        if (points.empty()) {
            fTrackStats = TrackStats(); // Reset to default
            return fTrackStats;
        }

        //Putting these here in case you don't have the header anymore and need them in the future!
        fTrackStats.TimeBinWidth = fTimeBinWidth;
        fTrackStats.FreqBinWidth = fFreqBinWidth;

        fTrackStats.StartTimeInRunC = points.front().TimeInRunC;
        fTrackStats.EndTimeInRunC   = points.back().TimeInRunC;
        fTrackStats.TimeLength      = points.back().TimeInRunC-points.front().TimeInRunC;


        fTrackStats.StartTimeInAcqC = points.front().TimeInAcqC;
        fTrackStats.EndTimeInAcqC   = points.front().TimeInAcqC + fTrackStats.TimeLength;

        fTrackStats.StartAcqID      = points.front().AcquisitionID;

        fTrackStats.StartFrequency  = points.front().Frequency;
        fTrackStats.EndFrequency    = points.back().Frequency;
        fTrackStats.FreqLength      = points.back().Frequency-points.front().Frequency;

        int nTimeBins = static_cast<int>(std::round(fTrackStats.TimeLength / fTrackStats.TimeBinWidth));
        int nFreqBins = static_cast<int>(std::round(fTrackStats.FreqLength / fTrackStats.FreqBinWidth));

        fTrackStats.BulkSlope = GetBulkSlope();
        fTrackStats.AcqFreqIntercept = ComputeAcqFreqIntercept();

        ComputeLocalSlopeStats(fTrackStats);
        ComputeSnrStats(fTrackStats);
        ComputePowerStats(fTrackStats);
        
        fTrackStats.ManhattanLength = nTimeBins+nFreqBins;
        fTrackStats.SNRPerUnitLength = 2*fTrackStats.TotalSnr/fTrackStats.ManhattanLength;

        return fTrackStats;
    }

   void Katydid::KTLongTrackData::ComputeBasicStats(
        const std::vector<double>& values,
        double& mean,
        double& stddev,
        double& min,
        double& max)
    {
        if (values.empty()) {
            mean = stddev = min = max = 0.0;
            return;
        }

        double sum = 0.0;
        min = max = values[0];

        for (double val : values) {
            sum += val;
            if (val < min) min = val;
            if (val > max) max = val;
        }

        mean = sum / values.size();

        double sq_sum = 0.0;
        for (double val : values) {
            sq_sum += (val - mean) * (val - mean);
        }

        stddev = std::sqrt(sq_sum / values.size());
    }


} /* namespace Katydid */
