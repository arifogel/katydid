/**
 @file KTSequentialLineData.hh
 @brief Contains KTSequentialLineData
 @details KTDiscriminatedPoint cluster with some track properties
 @author: agorman
 @date: March 7, 2024
 */

#ifndef KTLONGLINEDATA_HH
#define KTLONGLINEDATA_HH

#include "KTMemberVariable.hh"
#include "KTData.hh"
#include "KTDiscriminatedPoint.hh"

#include <string>
#include <vector>
#include <set>

namespace Katydid
{
    class KTLongTrackData : public Nymph::KTExtensibleData< KTLongTrackData >
    {
    public:
        struct TrackStats {
            double StartFrequency;
            double EndFrequency;
            double StartTime;
            double EndTime;
            double BulkSlope;
            double MeanLocalSlope;
            double MaxLocalSlope;
            double MinLocalSlope;
            double StdDevLocalSlope;
            double MeanSnr;
            double MaxSnr;
            double MinSnr;
            double StdDevSnr;
            double MeanPower;
            double MaxPower;
            double MinPower;
            double StdDevPower;
        };

        struct Point {
            double Frequency;
            double TimeInRunC;
            double TimeInAcqC;
            double AcquisitionID;
            double Amplitude;
            double Threshold;
            double SNR;
            double NoiseMean;
            double NoiseTau;
            double NoiseVariance;
            // Slope that the track finder computes to project forward when finding *next* point
            // Embedded here for debugging/observability as well as to memoize slope calculation which happens a lot
            double TrackFinderLocalSlope;

            Point(double timeInRunC, double timeInAcqC, double acqID, double frequency, double amplitude, double threshold, double snr, double noiseMean, double noiseTau, double noiseVariance, double trackFinderLocalSlope) :
                TimeInRunC(timeInRunC), TimeInAcqC(timeInAcqC),AcquisitionID(acqID),Frequency(frequency), Amplitude(amplitude), Threshold(threshold), SNR(snr), NoiseMean(noiseMean), NoiseTau(noiseTau),
                NoiseVariance(noiseVariance), TrackFinderLocalSlope(trackFinderLocalSlope) {}
        };

    public:
        unsigned TrackId;
        static const std::string sName;

        // Sorted by time
        std::vector<KTLongTrackData::Point> points;

    public:
        KTLongTrackData();
        ~KTLongTrackData() override;

        const std::vector<KTLongTrackData::Point>& GetPoints() const { return points; }
        void AddPoint(const Point& point);
//        void AddPoints(const Point& point);
        KTLongTrackData::TrackStats CalculateTrackStats() const;
        double GetBulkSlope() const;

        void SetPoints(const std::vector<KTLongTrackData::Point> &vector);
    };
} /* namespace Katydid */

#endif /* KTLONGLINEDATA_HH */


