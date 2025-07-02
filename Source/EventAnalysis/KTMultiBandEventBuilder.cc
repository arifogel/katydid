#include "KTMultiBandEventBuilder.hh"

#include "KTLogger.hh"
#include "KTDBSCAN.hh"
#include "KTLongTrackData.hh"
#include "KTMultiBandEventData.hh"

#include <cmath>
#include <numeric>
#include <algorithm>
#include <memory>

using std::set;
using std::vector;

namespace Katydid
{
    KTLOGGER(tclog, "katydid.fft");
    KT_REGISTER_PROCESSOR(KTMultiBandEventBuilder, "multi-band-event-builder");

    // Constructor
    KTMultiBandEventBuilder::KTMultiBandEventBuilder(const std::string& name) :
        KTProcessor(name),
        fEpsilon(0.5),
        fMinTracksInAcqToRun(1),
        fTimeBinWidth(0.0),
        fFreqBinWidth(0.0),
        fTracksPerAcq(),
        fNEventsEmitted(0),
        fMBESignal("mbe-cand", this),
        fEventBuilderDoneSignal("event-builder-done", this),
        fInputTrackSlot("long-track-cand", this, &KTMultiBandEventBuilder::ReceiveLongTrackCandidate)
    {
        RegisterSlot("build-events", this, &KTMultiBandEventBuilder::BuildEventsSlot);
    }

    // Destructor
    KTMultiBandEventBuilder::~KTMultiBandEventBuilder()
    {
        for (auto& entry : fTracksPerAcq)
        {
            for (auto* track : entry.second)
            {
                delete track;
            }
        }
        fTracksPerAcq.clear();
    }


    bool KTMultiBandEventBuilder::Configure(const scarab::param_node* node)
    {
        if (node == NULL) return false;
        SetEpsilon(node->get_value("epsilon", GetEpsilon()));
        return true;
    }

    // Receive track candidates
    bool KTMultiBandEventBuilder::ReceiveLongTrackCandidate(KTLongTrackData& trackData)
    {
        const auto& stats = trackData.GetTrackStats();
        KTDEBUG(tclog, "Received track with AcqID " << stats.StartAcqID << ", freq intercept = " << stats.AcqFreqIntercept );

        // Initialize bin widths from first track
        if (fTimeBinWidth == 0.0 && fFreqBinWidth == 0.0)
        {
            fTimeBinWidth = stats.TimeBinWidth;
            fFreqBinWidth = stats.FreqBinWidth;
            KTINFO(tclog, "Initialized global bin widths: time = " << fTimeBinWidth << ", freq = " << fFreqBinWidth);
        }

        // Store as raw pointer for ROOT compatability (and Nymph?)
        fTracksPerAcq[stats.StartAcqID].push_back(new KTLongTrackData(trackData));

        return true;
    }
    void KTMultiBandEventBuilder::BuildEventsSlot()
    {
        if (! Run())
        {
            KTERROR(tclog, "An error occurred while running the event builder");
        }
        return;
    }

    bool KTMultiBandEventBuilder::Run()
    {
        return BuildEvents();
    }

    // Build events when triggered
    bool KTMultiBandEventBuilder::BuildEvents()
    {
        KTINFO(tclog, "Building events from all acquisitions...");

        for (const auto& acqEntry : fTracksPerAcq)
        {
            unsigned acqID = acqEntry.first;
            const auto& tracks = acqEntry.second;

            KTINFO(tclog, "Processing AcqID " << acqID << " with " << tracks.size() << " tracks.");

            if (tracks.size() < fMinTracksInAcqToRun)
            {
                KTINFO(tclog, "Skipping AcqID " << acqID << " (not enough tracks: " << tracks.size() << ").");
                continue;
            }

            // Cluster the tracks
            std::vector<std::vector<KTLongTrackData*>> groupsInAcq = this->FindGroupsInAcq(tracks);
            EmitEvents(groupsInAcq);
        }

        KTINFO(tclog, "Event building complete. Emitted " << fNEventsEmitted << " events.");
        fEventBuilderDoneSignal();
        fTracksPerAcq.clear();
        return true;
    }

    // Placeholder clustering method
    std::vector<std::vector<KTLongTrackData*>> KTMultiBandEventBuilder::FindGroupsInAcq(const std::vector<KTLongTrackData*>& tracks)
    {
        std::vector<std::vector<KTLongTrackData*>> groupsInAcq;

        // TODO: Nick, implement real algorithm to cluster tracks into events here.
        // For now: treat all tracks in an aquisition as one single event
        if (!tracks.empty())
        {
            groupsInAcq.push_back(tracks);
        }

        return groupsInAcq;
    }

    void KTMultiBandEventBuilder::EmitEvents(const std::vector<std::vector<KTLongTrackData*>>& groupsInAcq)
    {
        // Package groupsInAcq into events
        for (const auto& group : groupsInAcq)
        {
            // Set up new data object
            Nymph::KTDataPtr data(new Nymph::KTData());
            KTMultiBandEventData& eventData = data->Of<KTMultiBandEventData>();

            for (const auto& track : group)
            {
                if (!track) continue;
                track->SetEventId(fNEventsEmitted);
                track->SetBandNumber(0); //Nick, this is where you assign the band number to a track object within the event. Or could be moved to FindGroupsInAcq
                eventData.AddTrack(track);
            }

            ++fNEventsEmitted;
            //fEventCandidates.insert(eventData);
            fMBESignal(data);
        }
    }

} // namespace Katydid
