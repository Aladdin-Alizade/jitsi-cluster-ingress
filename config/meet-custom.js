// JITSI_CUSTOM_15_USERS — live server (meet.ingress.academy) + recording
// 15 nəfərlik qruplar, 1080p, simulcast, Jibri recording

// az dil paketi jitsi-meet-web-də yoxdur (main-az.json 404) — join UI qıra bilər
config.defaultLanguage = 'en';
config.disableDeepLinking = true;

// XMPP client_proxy bəzən service-unavailable verir — HTTP focus allocation daha sabitdir
config.conferenceRequestUrl = 'https://__DOMAIN__/conference-request/v1';
config.focusUserJid = 'focus@auth.__DOMAIN__';

config.channelLastN = 15;
config.resolution = 1080;
config.constraints = {
    video: {
        height: { ideal: 1080, max: 1080, min: 180 }
    }
};

config.enableSimulcast = true;
config.disableSimulcast = false;
config.enableLayerSuspension = true;

// AV1 → JVB Av1DDQualityFilter crash (IndexOutOfBounds) — video düşür, iştirakçılar
// bir-birini görmür. VP8/VP9 ilə sabit qalır.
config.videoQuality = {
    codecPreferenceOrder: [ 'VP8', 'VP9', 'H264' ],
    mobileCodecPreferenceOrder: [ 'VP8', 'H264', 'VP9' ],
    screenshareCodec: 'VP8',
    mobileScreenshareCodec: 'VP8'
};
config.disabledCodecs = [ 'AV1' ];

config.desktopSharingFrameRate = { min: 5, max: 30 };

// 3+ nəfər üçün server üzərindən (live ilə eyni)
config.p2p = {
    enabled: false
};

config.startAudioMuted = 10;
config.startVideoMuted = 0;
config.startWithAudioMuted = true;
config.startWithVideoMuted = false;
config.enableNoAudioDetection = true;
config.enableNoisyMicDetection = true;

config.enableLobby = true;
config.enableClosePage = false;
config.prejoinPageEnabled = true;
config.prejoinConfig = {
    enabled: true,
    hideExtraJoinButtons: ['no-audio', 'by-phone']
};
config.enableWelcomePage = true;

config.analytics = {};
config.disableThirdPartyRequests = true;

config.toolbarButtons = [
    'microphone', 'camera', 'desktop', 'chat',
    'raisehand', 'participants-pane', 'tileview',
    'fullscreen', 'hangup', 'settings', 'recording'
];

config.filmstrip = {
    disableStageFilmstrip: false
};

// Prosody muc_max_occupants ilə uyğun
config.maxParticipants = 15;

// Server-side recording (Jibri → Bunny)
config.recordingService = {
    enabled: true,
    sharingEnabled: false,
    hideStorageWarning: true
};
config.liveStreamingEnabled = false;
config.fileRecordingsEnabled = true;
config.fileRecordingsServiceEnabled = false;
config.fileRecordingsServiceSharingEnabled = false;
config.hiddenDomain = 'recorder.__DOMAIN__';

// endConference (portal teacher leave) requires Prosody:
//   Component "endconference.__DOMAIN__" "end_conference"
// See setup-control.sh — applied on deploy / repair.
