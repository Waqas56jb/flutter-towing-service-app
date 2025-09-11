import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

class LocationPricingService {
  static const double basePkrPerKilometer = 100.0;
  static const Map<String, double> modeMultiplier = {
    'Bicycle': 0.6,   // lighter assistance
    'Car': 1.0,       // base
    'Truck': 1.8,     // heavy-duty towing
  };

  Future<Position> getCurrentPosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Location services are disabled');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permissions are permanently denied');
    }

    return Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
  }

  double calculateDistanceKm({
    required double startLat,
    required double startLng,
    required double endLat,
    required double endLng,
  }) {
    const double earthRadiusKm = 6371.0;
    final double dLat = _toRadians(endLat - startLat);
    final double dLon = _toRadians(endLng - startLng);

    final double lat1 = _toRadians(startLat);
    final double lat2 = _toRadians(endLat);

    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return earthRadiusKm * c;
  }

  double calculateFarePkr(double distanceKm, {String mode = 'Car'}) {
    final mult = modeMultiplier[mode] ?? 1.0;
    return (distanceKm * basePkrPerKilometer * mult).ceilToDouble();
  }

  double _toRadians(double degree) => degree * math.pi / 180.0;
}
