#ifndef KATMULTIBANDEVENTDATA_HH
#define KATMULTIBANDEVENTDATA_HH

#include "KTMemberVariable.hh"
#include "KTData.hh"
#include "KTLongTrackData.hh"

#include <vector>
#include <memory>
#include <string>

namespace Katydid
{
    class KTMultiBandEventData : public Nymph::KTExtensibleData<KTMultiBandEventData>
    {
        private:
            MEMBERVARIABLE(unsigned, EventId);
            MEMBERVARIABLE(double, AxialFrequency);

        public:
            static const std::string sName;
            KTMultiBandEventData();
            ~KTMultiBandEventData();

            // Add a track
            void AddTrack(KTLongTrackData* track);

            // Access tracks
            const std::vector<KTLongTrackData*>& GetTracks() const;

            // Clear tracks
            void ClearTracks();

            // CopyFrom
            void CopyFrom(const KTMultiBandEventData& rhs);

        private:
            // Store pointers to tracks
            std::vector<KTLongTrackData*> fTracks;;
    };

} // namespace Katydid

#endif
