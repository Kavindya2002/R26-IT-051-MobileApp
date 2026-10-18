# AegisCare — Intelligent Fall Monitoring and Prevention System

**Research Project | R26-IT-051**

AegisCare is an intelligent elderly-care system designed to support fall detection, activity recognition, environmental risk monitoring, cardiovascular monitoring, and adaptive alert management.

## Project Structure

```text
AegisCare-Monorepo/
├── frontend/                 # Flutter mobile application
│   ├── lib/
│   │   ├── screens/          # Application screens
│   │   ├── services/         # API communication
│   │   ├── models/           # Application data models
│   │   ├── theme/            # UI theme
│   │   └── widgets/          # Reusable UI components
│   ├── assets/               # Images and avatars
│   └── pubspec.yaml
│
├── backend/                  # FastAPI backend
│   ├── app/
│   │   ├── component1/        # Activity and fall recognition
│   │   ├── component2/        # Environmental risk analysis
│   │   ├── component3/        # Cardiovascular monitoring
│   │   ├── component4/        # Fall prevention and smart alerts
│   │   ├── integration/       # Component and MQTT integration
│   │   ├── users/             # User management
│   │   ├── elders/            # Elder management
│   │   └── main.py
│   ├── requirements.txt
│   └── .env.example
│
└── README.md
```

## System Components

| Component | Description |
|---|---|
| Component 1 | Activity recognition and fall detection |
| Component 2 | Environmental risk analysis |
| Component 3 | Cardiovascular monitoring using PPG data |
| Component 4 | Adaptive fall prevention, risk assessment, and smart alerts |

## Technology Stack

- **Mobile application:** Flutter and Dart
- **Backend API:** Python and FastAPI
- **Machine Learning:** Trained classification models, including XGBoost for alert decisions
- **Messaging:** MQTT with HiveMQ Cloud
- **Database and authentication:** Supabase
- **Sensor integration:** Accelerometer, gyroscope, and PPG sensor data

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/Kavindya2002/R26-IT-051-MobileApp.git
cd R26-IT-051-MobileApp
```

### 2. Configure the backend

```bash
cd backend
python -m venv .venv
```

Activate the virtual environment on Windows:

```powershell
.\.venv\Scripts\Activate.ps1
```

Install the dependencies:

```bash
pip install -r requirements.txt
```

Copy `.env.example` to `.env` and configure your own Supabase and HiveMQ credentials. Never commit your real `.env` file.

Run the backend from the `backend` directory:

```bash
uvicorn app.main:app --reload
```

### 3. Run the Flutter application

Open a second terminal:

```bash
cd frontend
flutter pub get
flutter run
```

Configure the API base URL in `frontend/lib/config.dart` to match your backend and device setup.

## Security

- Keep credentials and private keys out of Git.
- Use `.env` for local backend secrets.
- Configure production CORS origins appropriately.
- Never publish real database secret keys.

## Project Status

This repository contains the Flutter frontend and FastAPI backend for the AegisCare research project. Refer to the source code and configuration files for implementation details.