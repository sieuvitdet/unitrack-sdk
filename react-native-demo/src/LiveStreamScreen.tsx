// B2C live-stream + playback flow (screen_view "LiveStream").
// Each action fires camera_* events + a burst of network_request.
import React, {useRef} from 'react';
import {Text} from 'react-native';
import {Btn, Screen} from './ui';
import {CameraAnalytics, apiSequence, apiCall} from './cameraAnalytics';

export default function LiveStreamScreen({route}: any) {
  const cameraId = route?.params?.cameraId ?? 'cam_unknown';
  const cameraName = route?.params?.cameraName ?? 'Live stream';
  const streamStart = useRef<number>(0);

  const startStream = () => {
    streamStart.current = Date.now();
    CameraAnalytics.streamStarted(cameraId, '1080p');
    apiSequence([
      [`/v1/cameras/${cameraId}/stream/authorize`, 'POST', 200],
      [`/v1/cameras/${cameraId}/stream/manifest`, 'GET', 200],
      [`/v1/cameras/${cameraId}/stream/keyframe`, 'GET', 200],
      [`/v1/cameras/${cameraId}/ai/motion-zones`, 'GET', 200],
    ]);
    setTimeout(() => CameraAnalytics.streamFirstFrame(cameraId, 600), 600);
    setTimeout(() => {
      CameraAnalytics.streamBuffering(cameraId, 350);
      apiCall(`/v1/cameras/${cameraId}/stream/segment-retry`, 'GET', 503);
    }, 2000);
  };
  const stopStream = () => {
    if (!streamStart.current) return;
    CameraAnalytics.streamEnded(cameraId, Date.now() - streamStart.current);
    streamStart.current = 0;
  };

  return (
    <Screen>
      <Text style={{fontSize: 18, fontWeight: '700'}}>{cameraName}</Text>
      <Btn title="▶️  Bắt đầu xem trực tiếp" testID="stream_start" onPress={startStream} />
      <Btn title="⏸  Tạm dừng" testID="stream_pause" tone="plain"
        onPress={() => CameraAnalytics.streamPaused(cameraId)} />
      <Btn title="⏹  Dừng xem" testID="stream_stop" tone="plain" onPress={stopStream} />
      <Btn title="🎞  Xem sự kiện chuyển động" testID="event_view" tone="plain"
        onPress={() => {
          CameraAnalytics.eventViewed(cameraId, 'motion');
          apiSequence([
            [`/v1/cameras/${cameraId}/events?type=motion`, 'GET', 200],
            [`/v1/cameras/${cameraId}/events/thumbnail`, 'GET', 404],
          ]);
        }} />
      <Btn title="⏮  Phát lại bản ghi" testID="playback_start" tone="plain"
        onPress={() => {
          CameraAnalytics.playbackStarted(cameraId, 'rec_20260529_1430');
          apiSequence([
            ['/v1/recordings/rec_20260529_1430/manifest', 'GET', 200],
            ['/v1/recordings/rec_20260529_1430/segments', 'GET', 200],
          ]);
          setTimeout(() => CameraAnalytics.playbackEnded(cameraId, 1500), 1500);
        }} />
    </Screen>
  );
}
