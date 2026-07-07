export interface CameraConfig {
  id: string;
  name: string;
  stream_name: string;
  source_url: string;
  archive_storage?: 'node' | 'device' | 'both';
  rtmp_push_url: string | null;
  retention_days: number;
  is_enabled: boolean;
  device_id?: string | null;
  device_connection_type?: string | null;
  device_archive_storage?: 'node' | 'device' | 'both' | null;
  device_host?: string | null;
  device_port?: number | null;
  device_username?: string | null;
  device_password?: string | null;
  device_rtsp_url?: string | null;
  onvif_xaddr?: string | null;
  onvif_port?: number | null;
  onvif_username?: string | null;
  onvif_password?: string | null;
  onvif_profile_token?: string | null;
}

export interface SegmentInfo {
  relativePath: string;
  absolutePath: string;
  timestamp: Date;
}
