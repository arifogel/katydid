/**
 @file KTLongTrackData.cc
 @brief Contains KTLongTrackData
 @details KTDiscriminatedPoint cluster with some track properties
 @author: agorman
 @date: March 7, 2024
 */
#include <KTLongTrackData.hh>

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

//    const KTLongTrackData::TrackStats CalculateTrackStats() const;
    double KTLongTrackData::GetBulkSlope() const {
        if(points.size() < 2) { return 0; }

        return (points.front().Frequency - points.back().Frequency) / (points.front().Time - points.back().Time);
    }

    // Copies vector of points to internal points vector
    void KTLongTrackData::SetPoints(const std::vector<KTLongTrackData::Point> &pointsToCopy) {
        points = pointsToCopy;

        // Sorts points by time so that earlier points are first
        auto timeSorter = [] (auto first, auto second) { return first.Time < second.Time; };
        if(!std::is_sorted(points.begin(), points.end(), timeSorter)) {
            std::sort(points.begin(), points.end(), timeSorter);
        }
    }

    void KTLongTrackData::AddPoint(const KTLongTrackData::Point &point) {
        points.push_back(point);
    }

    KTLongTrackData::TrackStats KTLongTrackData::CalculateTrackStats() const {
        return KTLongTrackData::TrackStats();
    }
} /* namespace Katydid */
