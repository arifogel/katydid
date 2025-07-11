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

//From https://en.wikipedia.org/wiki/Partition_of_a_set: A partition of a set is a grouping of its elements into non-empty subsets, in such a way that every element is included in exactly one subset
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
        fTrackFrequencyBandwidths({2300,360,3}),
        fMBESignal("mbe-cand", this),
        fEventBuilderDoneSignal("event-builder-done", this),
        fInputTrackSlot("long-track-cand", this, &KTMultiBandEventBuilder::ReceiveLongTrackCandidate)
    {
        RegisterSlot("build-events", this, &KTMultiBandEventBuilder::BuildEventsSlot);

        for(unsigned k = 0; k <= fMaxTracksInAcqToRun; ++k)
        {
            fLogPoisson.push_back(k*std::log(fExpectedTracksPerAcq) - fExpectedTracksPerAcq - std::log(std::tgamma(k+1)));
            KTINFO(tclog,"Poisson log-likelihood("<<k<<")= "<<fLogPoisson[k]);
        }
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
        SetExpectedTracksPerAcq(node->get_value("expected-tracks-per-acq", GetExpectedTracksPerAcq()));
        return true;
    }

    // Receive track candidates
    bool KTMultiBandEventBuilder::ReceiveLongTrackCandidate(KTLongTrackData& trackData)
    {
        const auto& stats = trackData.GetTrackStats();
        KTINFO(tclog, "Received track with AcqID " << stats.StartAcqID << ", freq intercept = " << stats.AcqFreqIntercept );

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

        for (auto& acqEntry : fTracksPerAcq)
        {
            unsigned acqID = acqEntry.first;
            auto& tracks = acqEntry.second;

            KTINFO(tclog, "Sorting AcqID " << acqID << " with " << tracks.size() << " tracks.");

            std::sort(tracks.begin(), tracks.end(), [](const auto& a, const auto& b) {return a->GetTrackStats().AcqFreqIntercept < b->GetTrackStats().AcqFreqIntercept;});


            if (tracks.size() < fMinTracksInAcqToRun)
            {
                KTINFO(tclog, "Skipping AcqID " << acqID << " (not enough tracks: " << tracks.size() << ").");
                continue;
            }

            if (tracks.size() > 1)
            {
                for(int i=0;i<tracks.size();++i)
                    KTINFO(tclog, "AcqID " << acqID << ", Sorted Track "<< i << ", AcqFreqIntercept: "<< tracks[i]->GetTrackStats().AcqFreqIntercept);
            }

            // Cluster the tracks
            // TODO: If there is a gap > fTrackFrequencyBandwidths[1], split up tracks into multiple calls.
            //since there are no possible clusters between
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
        //returns a vector with all possible partitions of (integer-labelled) tracks in an acq [vec<vec<vec<int>>>]
        if(nTracks > fMaxTracksInAcqToRun)
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

        const int nTracksInAcq = tracks.size();
        KTWARN(tclog, "nTracks: " << nTracksInAcq << " ack.");

        // If one track in acq, treat all tracks in an acquisition as one single event
        if(nTracksInAcq <= 1)
        {
            groupsInAcq.push_back(tracks);
        }
        else if(nTracksInAcq > fMaxTracksInAcqToRun)
        {
            //if nTracks > ~15 throw an error: too memory-intensive to list all possible partitions
            //Treat all tracks as a single event so that it is easy to find, if it ever happens
            groupsInAcq.push_back(tracks);
            KTWARN(tclog, nTracksInAcq << " tracks were found in trap acq! Brute force failed, clustering skipped!");
        }
        else
        {
            //"standard" and non-trivial case for track clustering
            auto partitions = GetAllPartitions(nTracksInAcq);
            const int nPartitions = partitions.size(); //Bell number: B_nTracksInAcq
            std::vector<double> logLikelihoods(nPartitions); //vector of zeros for each proposed partition

            //For each proposed partition, count how many events are proposed
            std::vector<int> nEvents(nPartitions);
            //For each proposed partition, count how many bands are in each proposed event
            std::vector<std::vector<int>> nBands(nPartitions);
            for(int i = 0; i<nPartitions;++i)
            {
                nEvents.push_back(partitions[i].size());
                for (const auto& subset : partitions[i])
                {
                    nBands[i].push_back(subset.size());
                }
            }
            std::vector<std::vector<int>> labels = nBands;


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
                track->SetBandNumber(0);
                eventData.AddTrack(track);
            }

            ++fNEventsEmitted;
            //fEventCandidates.insert(eventData);
            fMBESignal(data);
        }
    }

} // namespace Katydid
