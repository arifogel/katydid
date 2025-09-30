#include "KTMultiBandEventBuilder.hh"

#include "KTLogger.hh"
#include "KTDBSCAN.hh"
#include "KTLongTrackData.hh"
#include "KTMultiBandEventData.hh"

#include <algorithm>
#include <cmath>
#include <limits>
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
        //fEventTopologies({"00000","00100","01010","01110","11011","1101","1011","11001","10011"}),
        fBandLabels({{},{0},{-1,1},{-1,0,1},{-2,-1,1,2},{-2,-1,1},{-1,1,2},{-2,-1,2},{-2,1,2}}),
        fExpectedTracksPerAcq(0.05),
        fSetField(1.0),
        fVoltageOnTime(0.0018296),
        fVoltageOffTime(0.002),
        fMinTracksInAcqToRun(1),
        fMaxTracksInAcqToRun(15),
        fTimeBinWidth(0.0),
        fFreqBinWidth(0.0),
        fTracksPerAcq(),
        fNEventsEmitted(0),
        fTrackFrequencyBandwidths({2300e6,360e6,3e6}),
        fLogTrackFrequencyBandwidths(),
        fMBESignal("mbe-cand", this),
        fEventBuilderDoneSignal("event-builder-done", this),
        fInputTrackSlot("long-track-cand", this, &KTMultiBandEventBuilder::ReceiveLongTrackCandidate)
    {
        RegisterSlot("build-events", this, &KTMultiBandEventBuilder::BuildEventsSlot);

        //Need MaxTracks + 1 to prevent segfaults if there are exactly maxTracks in the trap acq
        fLogEventSizePrior = std::vector<double>(fMaxTracksInAcqToRun + 1);
        fLogTrackFrequencyBandwidths = std::vector<double>(fMaxTracksInAcqToRun + 1);
        //manual hardcoding of priors (could change, via config list with remaining entries set to -inf
        //normalized so that over all eventTypes, sum is 1. Only relative values really matter for selection
        fLogEventSizePrior[1] = 0.3;
        fLogEventSizePrior[2] = 0.5;
        fLogEventSizePrior[3] = 0.18 / 5.;
        fLogEventSizePrior[4] = 0.02;

        const unsigned nTrackFrequencyBandwidths = fTrackFrequencyBandwidths.size();
        for(unsigned k = 0; k <= fMaxTracksInAcqToRun; ++k)
        {
            fLogPoisson.push_back(k*std::log(fExpectedTracksPerAcq) - fExpectedTracksPerAcq - std::log(std::tgamma(k+1)));
            KTINFO(tclog,"Poisson log-likelihood("<<k<<")= "<<fLogPoisson[k]);

            fLogEventSizePrior[k] = std::log(fLogEventSizePrior[k]);
            KTINFO(tclog,"Event Prior log-likelihood("<<k<<")= "<<fLogEventSizePrior[k]);

            fLogTrackFrequencyBandwidths[k] = -std::log(fTrackFrequencyBandwidths[std::min(k, nTrackFrequencyBandwidths)]);
            //KTINFO(tclog,"Event Prior log-likelihood("<<k<<")= "<<fLogEventSizePrior[k]);
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
        SetSetField(node->get_value("set-field", GetSetField()));
        SetVoltageOnTime(node->get_value("voltage-on-time", GetVoltageOnTime()));
        SetVoltageOffTime(node->get_value("voltage-off-time", GetVoltageOffTime()));
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
       if(current >= nTracks)
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

    std::vector<unsigned> KTMultiBandEventBuilder::GetMaxLIndices(const std::vector<double>& logLikelihoods, const double &tolerance)
    {
        //returns the partition indices of all likelihoods within tol of the max
        std::vector<unsigned> indices;
        //this is unironically how C++ does this: max doesn't work for vectors
        double maxL = *std::max_element(logLikelihoods.begin(), logLikelihoods.end());

        for (size_t i = 0; i < logLikelihoods.size(); ++i)
        {
            if (std::fabs(logLikelihoods[i] - maxL) <= tolerance)
                indices.push_back(i);
        }

        return indices;
    }

    std::pair<unsigned, double> KTMultiBandEventBuilder::LLHDataGivenEvent(const std::vector<KTLongTrackData*>& allTracks, const std::vector<unsigned short>& inds)
    {
        std::vector<KTLongTrackData*> tracks;
        std::transform(inds.begin(), inds.end(), std::back_inserter(tracks), [allTracks](unsigned i) { return allTracks[i];});

        //key function that given a vector of track objects, evalautes the logLikelihood of the data being consistent with the proposed event clustering
        // return pair for the event class label (which we need for len(3) events) and the LLH
        const unsigned nTracks = tracks.size();
        double logL = fLogTrackFrequencyBandwidths[0];
        unsigned label = nTracks;
        const double neg_inf = -std::numeric_limits<double>::infinity();
        std::pair<unsigned, double> outputInfo = {label, logL};

        if(nTracks == 1)
            return outputInfo;
        else if(nTracks > 4)
            return std::pair<unsigned, double>(label,neg_inf);

        //Checks if any pairs of bands are too far apart, slopes cross, or times don't overlap
        //Returns false if proposed event is bad in anyway, set LLH to -inf
        if(!CheckEventGoodness(allTracks, inds))
            return std::pair<unsigned, double>(label,neg_inf);

        //Get vector of freqs
        std::vector<double> freqs(nTracks);
        std::transform(tracks.begin(), tracks.end(), freqs.begin(), [](const auto& a){return a->GetTrackStats().AcqFreqIntercept;});

        //Get vector of freq differences
        std::vector<double> dfreqs(nTracks-1);
        std::transform(freqs.begin() + 1, freqs.end(), freqs.begin(), dfreqs.begin(), std::minus<>());

        if(nTracks == 4)
        {
            //Should first condition be 2x looser? Unsure... throw out proposal if spacings inconsistent w/ 11011 event
            if((std::fabs(dfreqs[1] - 2*dfreqs[0]) > fTrackFrequencyBandwidths[2]) or (std::fabs(dfreqs[2] - dfreqs[0]) > fTrackFrequencyBandwidths[2]))
                return std::pair<unsigned, double>(label,neg_inf);
        }
        else if(nTracks == 3)
        {
            //look for 3-band events: 111,1101,1011,11001,10011. To do this, we see which frequency gap is bigger, and the ratio of the frequency gaps
            //The ratio will be 1:1, 1:2, 2:1, 1:3, 3:1 respectively
            // for the 3 bands [0,1,2], set this variable to 1 if 01 freq gap is bigger than 12 freq. gap
            int biggerFirstDeltaFreq = (dfreqs[0] > dfreqs[1]);
            std::pair<double, double> sortedDFreqs = std::minmax(dfreqs[0], dfreqs[1]);

            std::vector<unsigned> validDFratio;
            for(unsigned allowed_ratio = 1; allowed_ratio <= 3; ++allowed_ratio)
            {
                if(std::fabs(sortedDFreqs.second - allowed_ratio * sortedDFreqs.first) < fTrackFrequencyBandwidths[2])
                    validDFratio.push_back(allowed_ratio);
            }

            if(!validDFratio.size())
                return std::pair<unsigned, double>(label,neg_inf);

            //event_topologies = [["111","111"],["1101","1011"],["11001","10011"]]
            std::vector<std::vector<unsigned>> lenThreeEventLabels = {{3,3},{5,6},{7,8}};
            outputInfo.first = lenThreeEventLabels[validDFratio[0] - 1][biggerFirstDeltaFreq];
        }

        return outputInfo;
    }


    bool KTMultiBandEventBuilder::CheckEventGoodness(const std::vector<KTLongTrackData*>& allTracks, const std::vector<unsigned short>& inds)
    {
        std::vector<KTLongTrackData*> tracks;
        std::transform(inds.begin(), inds.end(), std::back_inserter(tracks), [allTracks](unsigned i) { return allTracks[i];});

        const unsigned nTracks = tracks.size();
        //For any condition which is "not allowed", set LLH to negative infinity
        //There will always be a non-neg-inf partition, if all tracks are separate events (nTracks == 1) for all tracks
        //because we already sorted tracks by AcqFreqIntercept (ascending)
        if((tracks.back()->GetTrackStats().AcqFreqIntercept - tracks.front()->GetTrackStats().AcqFreqIntercept) > fTrackFrequencyBandwidths[1])
            return false;
        //Get copy of tracks sorted by start time (ascending)
        auto tracksStartTimeSort = tracks;
        std::sort(tracksStartTimeSort.begin(), tracksStartTimeSort.end(), [](const auto& a, const auto& b) {return a->GetTrackStats().StartTimeInRunC < b->GetTrackStats().StartTimeInRunC;});
        //Given list of tracks sorted by start times, if the next start time is after the maximum end time of the tracks seen so far
        //there is a time gap in the event structure, and we are saying the event is not allowed
        double maxEndTime = tracksStartTimeSort[0]->GetTrackStats().EndTimeInRunC;
        for(unsigned i=1;i<nTracks;++i)
        {
            if(tracks[i]->GetTrackStats().StartTimeInRunC > maxEndTime)
                return false;

            maxEndTime = std::max(maxEndTime, tracks[i]->GetTrackStats().EndTimeInRunC);
        }

        //Check if any pairs of bands are projected to cross over the trap acq. If so, the event should not be joined together
        std::vector<double> endFreqInts(nTracks);
        std::transform(tracks.begin(), tracks.end(), endFreqInts.begin(),
            [this](const auto& a) {
                return a->GetTrackStats().AcqFreqIntercept +
                       a->GetTrackStats().BulkSlope * fVoltageOffTime;
            });
        if(!std::is_sorted(endFreqInts.begin(), endFreqInts.end()))
            return false;

        //if none of the (bad) conditions above are hit, the event is "allowable". It may still be killed later.
        return true;
    }

    // clustering method
    std::vector<std::vector<KTLongTrackData*>> KTMultiBandEventBuilder::FindGroupsInAcq(const std::vector<KTLongTrackData*>& tracks)
    {
        std::vector<std::vector<KTLongTrackData*>> groupsInAcq;

        // Separate tracks into two groups: clusterable vs immediate emit
        std::vector<KTLongTrackData*> clusterable;

        for (auto* track : tracks)
        {
            double start = track->GetTrackStats().StartTimeInAcqC;
            KTINFO(tclog, "Track start time: " << start << ", fVoltageOnTime: " << fVoltageOnTime);

            if (start < fVoltageOnTime)
            {
                clusterable.push_back(track);
            }
            else
            {
                std::vector<KTLongTrackData*> emptying_track{track};
                // Each track that starts in the exb emptying emmited as it's own event. (BN=0)
                groupsInAcq.push_back(emptying_track);
            }
        }

        const int nTracksInAcq = clusterable.size();
        KTWARN(tclog, "nTracksInAcq: " << nTracksInAcq);

        // If one track in acq, treat all tracks in an acquisition as one single event
        if(nTracksInAcq <= 1)
        {
            groupsInAcq.push_back(clusterable);
        }
        else if(nTracksInAcq > fMaxTracksInAcqToRun)
        {
            //if nTracks > ~15 throw an error: too memory-intensive to list all possible partitions
            //Treat all tracks as a single event so that it is easy to find, if it ever happens
            groupsInAcq.push_back(clusterable);
            KTWARN(tclog, nTracksInAcq << " tracks were found in trap acq! Brute force failed, clustering skipped!");
        }
        else
        {
            //"standard" and non-trivial case for track clustering
            auto partitions = GetAllPartitions(nTracksInAcq);
            const int nPartitions = partitions.size(); //Bell number: B_nTracksInAcq
            std::vector<double> logLikelihoods(nPartitions); //vector of zeros for each proposed partition

            //DO WE ACTUALLY USE THESE, EVER???
            //For each proposed partition, count how many events are proposed
            //std::vector<int> nEvents(nPartitions);
            //For each proposed partition, count how many bands are in each proposed event
            //std::vector<std::vector<int>> nBands(nPartitions);
            std::vector<std::vector<unsigned>> labels(nPartitions);

            for(int i = 0; i<nPartitions;++i)
            {
                //nEvents.push_back(partitions[i].size());
                //partitions[i].size() is number of events in the proposed partition. Add poisson prob. of this
                logLikelihoods[i] += fLogPoisson[partitions[i].size()];

                for (const auto& subset : partitions[i])
                {
                    //nBands[i].push_back(subset.size());
                    labels[i].push_back(subset.size());
                    //subset.size() is number of bands in a proposed event, in the proposed partition. Add log prior for this
                    //By assumption, we use equal priors for all events with the same number of bands
                    logLikelihoods[i] += fLogEventSizePrior[subset.size()];
                }
            }

            ////////////////////////Actually evaluate the LLHs, given data //////////////////////
            for(int i = 0; i<nPartitions;++i)
            {
                //for (const auto& ev: partitions[i])
                for(int j = 0; j<partitions[i].size();++j)
                {
                    std::pair<unsigned, double> llhResult =  LLHDataGivenEvent(clusterable,partitions[i][j]);
                    if(std::isinf(llhResult.second))
                        break;

                    logLikelihoods[i] += llhResult.second;
                    labels[i][j] = llhResult.first;
                }
            }

            ////////////////////////Pick out the best partition//////////////////////
            std::vector<unsigned> bestPartitionIndices = GetMaxLIndices(logLikelihoods, 1e-2);
            if(bestPartitionIndices.size() == 0) 
            {
                KTERROR(tclog, "No optimal event partition found! Should never happen!");
            }
            else if(bestPartitionIndices.size() > 1) 
            {
                KTWARN(tclog, "Multiple optimal partitions found! Just returning first (for now)")
            }

            unsigned bestIndex = bestPartitionIndices.front();
            partition bestPartition = partitions[bestIndex];
            unsigned nEventsBest = bestPartition.size();

            std::vector<std::vector<KTLongTrackData*>> optimalTracks(nEventsBest);

            for(unsigned i = 0; i < nEventsBest;++i)
            {
                std::transform(bestPartition[i].begin(), bestPartition[i].end(), std::back_inserter(optimalTracks[i]), [clusterable](unsigned i) { return clusterable[i];});

                unsigned eventLabel = labels[bestIndex][i];
                KTINFO(tclog, "Event found with label "<<eventLabel);
                for(unsigned j=0;j<optimalTracks[i].size();++j)
                {
                    optimalTracks[i][j]->SetBandNumber(fBandLabels[eventLabel][j]);
                    KTWARN(tclog, "Band "<<j<<" labelled with "<<fBandLabels[eventLabel][j]);
                }
            }

            //return optimalTracks;
            groupsInAcq.insert(groupsInAcq.end(),
                   std::make_move_iterator(optimalTracks.begin()),
                   std::make_move_iterator(optimalTracks.end()));
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
                track->SetEventType(1); 
                eventData.AddTrack(track);
            }

            ++fNEventsEmitted;
            //fEventCandidates.insert(eventData);
            fMBESignal(data);
        }
    }

} // namespace Katydid
