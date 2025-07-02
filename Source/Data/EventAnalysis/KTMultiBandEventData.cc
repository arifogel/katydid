/**
 @file KTMultiBandEventData.cc
 @brief Contains KTMultiBandEventData
 @details conatians pointers to the tracks in this event, and event properties
 @author: H.S. Harrington
 @date: June 30 2025
 */

#include <KTMultiBandEventData.hh>
#include <KTLongTrackData.hh>
#include "KTSliceHeader.hh"
#include "KTLogger.hh"

#include <iostream>

namespace Katydid
{
    const std::string KTMultiBandEventData::sName("mbe");
    KTLOGGER(mbelog, "KTMBE");

    KTMultiBandEventData::KTMultiBandEventData():
        fEventId(),
        fAxialFrequency(),
        fTracks()
        {}
    
    KTMultiBandEventData::~KTMultiBandEventData() {}

    void KTMultiBandEventData::AddTrack(KTLongTrackData* track)
    {
        if (track) fTracks.push_back(track);
    }

    const std::vector<KTLongTrackData*>& KTMultiBandEventData::GetTracks() const
    {
        return fTracks;
    }

    void KTMultiBandEventData::ClearTracks()
    {
        fTracks.clear();
    }

    void KTMultiBandEventData::CopyFrom(const KTMultiBandEventData& rhs)
    {
        fTracks = rhs.fTracks;
    }

} // namespace Katydid
