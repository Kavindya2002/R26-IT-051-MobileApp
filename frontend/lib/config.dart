/// ---------------------------------------------------------------
/// CHANGE THIS to point at your running FastAPI backend.
///
/// - Android emulator talking to a backend on your PC:  http://10.0.2.2:8000
/// - iOS simulator talking to a backend on your Mac:    http://172.20.10.2:8000
/// - Real physical phone (same wifi as your PC):        http://<your-pc-lan-ip>:8000
/// - Deployed backend (Render/Railway/etc.):            https://your-app.onrender.com
/// ---------------------------------------------------------------
class AppConfig {
  static const String baseUrl = "http://172.20.10.2:8000";

  // How often the dashboard polls the backend for fresh sensor data.
  static const Duration pollInterval = Duration(seconds: 5);
}
