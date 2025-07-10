#include "KTMultiBandEventBuilder.hh"

#include "KTLogger.hh"
#include "KTDBSCAN.hh"
#include "KTLongTrackData.hh"
#include "KTMultiBandEventData.hh"

#include <algorithm>
#include <cmath>
#include <memory>
#include <numeric>
#include <stdexcept>

//using std::set;
//using std::vector;

//bands are sorted by FreqIntInTrapAcq and assigned integers starting at 0
//We would have (for proposed events): event = vector<band>
//Then a given "partition" is a vector<event>, in which we organize all bands in a trap acq. into events
//We have vector<partition> to consider all partitions from which choose the maximal likelihood partition

namespace Katydid
{
    KTLOGGER(tclog, "katydid.fft");
    KT_REGISTER_PROCESSOR(KTMultiBandEventBuilder, "multi-band-event-builder");

    // Constructor
    KTMultiBandEventBuilder::KTMultiBandEventBuilder(const std::string& name) :
        KTProcessor(name),
        fExpectedTracksPerAcq(0.05),
        fMinTracksInAcqToRun(1),
        fMaxTracksInAcqToRun(15),
        fTimeBinWidth(0.0),
        fFreqBinWidth(0.0),
        fTracksPerAcq(),
        fNEventsEmitted(0),
        fLogPoisson(fMaxTracksInAcqToRun),
        fTrackFrequencyBandwidths({2300,360,3}),
        fMBESignal("mbe-cand", this),
        fEventBuilderDoneSignal("event-builder-done", this),
        fInputTrackSlot("long-track-cand", this, &KTMultiBandEventBuilder::ReceiveLongTrackCandidate)
    {
        RegisterSlot("build-events", this, &KTMultiBandEventBuilder::BuildEventsSlot);

        for(unsigned k = 0; k < fMaxTracksInAcqToRun; ++k)
            fLogPoisson[k] = k*std::log(fExpectedTracksPerAcq) - fExpectedTracksPerAcq - std::log(std::tgamma(k+1));
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
        //SetEpsilon(node->get_value("epsilon", GetEpsilon()));
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


    void KTMultiBandEventBuilder::RecursivePartitionGenerator(const int &nTracks, unsigned short current, const partition& current_partition, std::vector<partition>& result)
    {
       if(current > nTracks)
       {
           result.push_back(current_partition);
           return;
       }

        for (size_t i = 0; i < current_partition.size(); ++i)
        {
            partition new_partition = current_partition;
            new_partition[i].push_back(current);
            RecursivePartitionGenerator(nTracks, current + 1, new_partition, result);
        }

        partition new_partition = current_partition;
        new_partition.push_back({current});
        RecursivePartitionGenerator(nTracks, current + 1, new_partition, result);
    }

    std::vector<partition> KTMultiBandEventBuilder::GetAllPartitions(const int &nTracks)
    {
        //if nTracks > ~15 throw an error so that we don't wait longer than universe lifetime to list all possibilities
        if( nTracks > 15)
            throw std::runtime_error("Number of bands in trap acq > 15! Requires ~GB of storage for all possibilities");
        std::vector<partition> result;
        partition current_partition;
        RecursivePartitionGenerator(nTracks, 0, current_partition, result);
        return result;
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

        const int nTracksInAcq = tracks.size();
        KTINFO(tclog, "nTracks: " << nTracksInAcq << " ack.");

        //auto partitions = get_all_partitions(nTracksInAcqnBandsInTrapAcq);

        //const int nPartitions = partitions.size();

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
                track->SetBandNumber(0);
                eventData.AddTrack(track);
            }

            ++fNEventsEmitted;
            //fEventCandidates.insert(eventData);
            fMBESignal(data);
        }
    }

} // namespace Katydid
