/**
 @file KTLongTrackData.hh
 @brief Contains KTSequentialLineData
 @details Discriminated Point cluster with some track properties
 @Authors: A. Gorman, H.S. Harrington
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
            double FreqLength;
            double StartTimeInRunC;
            double EndTimeInRunC;
            double TimeLength;
            double StartTimeInAcqC;
            double EndTimeInAcqC;
            unsigned StartAcqID;
            double AcqFreqIntercept; //from bulk slope
            double BulkSlope;
            double MeanLocalSlope;
            double MaxLocalSlope;
            double MinLocalSlope;
            double StdDevLocalSlope;
            double TotalNsp;
            double MeanNsp;
            double MaxNsp;
            double MinNsp;
            double StdDevNsp;
            double TotalPower;
            double MeanPower;
            double MaxPower;
            double MinPower;
            double StdDevPower;
            double TimeBinWidth;
            double FreqBinWidth;
            double ManhattanLength;
            double Density;
            double NSPPerUnitLength;
            double DensityEstSNR;
            double MLEPowerSNR;
        };

        struct Point {
            double Frequency;
            double TimeInRunC;
            double TimeInAcqC;
            double AcquisitionID;
            double Ordinate;
            double Threshold;
            double NSP;
            double NoiseMean;
            double NoiseTau;
            double NoiseVariance;
            // Slope that the track finder computes to project forward when finding *next* point
            // Embedded here for debugging/observability as well as to memoize slope calculation which happens a lot
            double TrackFinderLocalSlope;

            Point(double timeInRunC, double timeInAcqC, int acqID, double frequency, double ordinate, double threshold, double nsp, double noiseMean, double noiseTau, double noiseVariance, double trackFinderLocalSlope) :
                TimeInRunC(timeInRunC), TimeInAcqC(timeInAcqC),AcquisitionID(acqID),Frequency(frequency), Ordinate(ordinate), Threshold(threshold), NSP(nsp), NoiseMean(noiseMean), NoiseTau(noiseTau),
                NoiseVariance(noiseVariance), TrackFinderLocalSlope(trackFinderLocalSlope) {}
        };

    private:
            MEMBERVARIABLE(unsigned, TrackId);
            MEMBERVARIABLE(unsigned, EventId);
            MEMBERVARIABLE(int, BandNumber);
            MEMBERVARIABLE(int, EventType);
            MEMBERVARIABLE(double, AxialFreq);
    public:
        static const std::string sName;

        // Sorted by time
        std::vector<KTLongTrackData::Point> points;
        TrackStats fTrackStats;

        KTLongTrackData();
        ~KTLongTrackData() override;

        const std::vector<KTLongTrackData::Point>& GetPoints() const { return points; }
        const TrackStats& GetTrackStats() const { return fTrackStats; }
        void AddPoint(const Point& point);
//        void AddPoints(const Point& point);
        const TrackStats& CalculateTrackStats(double fTimeBinWidth,double fFreqBinWidth);
        double GetBulkSlope() const;
        double ComputeAcqFreqIntercept() const;
        double LogLikelihood(double lambda, const std::vector<double>& chi_vals);
        double ComputeMaxLoglikelihoodLambda();
        double EstimateLambdaFromDensity(double Density);
        void SetPoints(const std::vector<KTLongTrackData::Point> &vector);

    private:
        void ComputeLocalSlopeStats(TrackStats& stats) const;
        void ComputeNspStats(TrackStats& stats) const;
        void ComputePowerStats(TrackStats& stats) const;

        static void ComputeBasicStats(const std::vector<double>& values,
                                      double& mean,
                                      double& stddev,
                                      double& min,
                                      double& max);

    };
} /* namespace Katydid */

#endif /* KTLONGLINEDATA_HH */


