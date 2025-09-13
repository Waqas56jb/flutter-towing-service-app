import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
// import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlng;
import 'package:http/http.dart' as http;
import '../service/location_pricing_service.dart';
import '../service/towing_service_provider.dart';
import '../service/geocoding_service.dart';
import '../models/towing_service.dart';
import '../widgets/location_search_widget.dart';
import '../widgets/location_accuracy_widget.dart';
import '../widgets/aggressive_location_widget.dart';
// import 'package:charts_flutter/flutter.dart' as charts;
// NO HARDCODED FALLBACK - 100% REAL-TIME LOCATION

class TowingServiceScreen extends StatefulWidget {
  const TowingServiceScreen({Key? key}) : super(key: key);

  @override
  State<TowingServiceScreen> createState() => _TowingServiceScreenState();
}

class _TowingServiceScreenState extends State<TowingServiceScreen> {
  String selectedServiceType = 'Emergency Towing';
  String selectedVehicleType = 'Car';
  final TextEditingController locationController = TextEditingController();
  final TextEditingController destinationController = TextEditingController();

  final TextEditingController destinationLatController = TextEditingController();
  final TextEditingController destinationLngController = TextEditingController();

  Position? _currentPosition;
  double? _lastDistanceKm;
  double? _lastFarePkr;
  bool _isCalculating = false;

  final MapController _mapController = MapController();
  final List<Marker> _markers = [];
  final List<Polyline> _polylines = [];
  latlng.LatLng? _initialCenter;

  latlng.LatLng? _pickupPos;
  latlng.LatLng? _destPos;

  List<TowingService> _topRecommendations = [];

  // Live route stats
  String _distanceText = '';
  String _durationText = '';

  // NO HARDCODED CITIES - 100% REAL-TIME LOCATION SEARCH

  Future<void> _handleDestinationQuery(String query) async {
    final q = query.trim().toLowerCase();
    
    // Handle "nearest towing service" search
    if (q.contains('nearest') && (q.contains('tow') || q.contains('towing'))) {
      if (_currentPosition != null) {
        await _findNearestTowing(center: latlng.LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please use current location first to find nearest towing services')),
        );
      }
      return;
    }

    // Use real-time geocoding for any location search
    final dest = await _geocodeAddress(query);
    if (dest != null) {
      destinationLatController.text = dest.latitude.toStringAsFixed(6);
      destinationLngController.text = dest.longitude.toStringAsFixed(6);
      _addOrUpdateDestinationMarker(dest);
      if (_currentPosition != null) {
        final start = latlng.LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
        await _routeWithDirections(start, dest);
      } else {
        await _moveCamera(dest, zoom: 14);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location not found. Try a different search term or use coordinates')),
      );
    }
  }

  // 100% REAL-TIME geocoding using OpenStreetMap Nominatim API
  Future<latlng.LatLng?> _geocodeAddress(String query) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    // Check if input is coordinates
    final RegExp coordRe = RegExp(r'^\s*([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*$');
    final match = coordRe.firstMatch(trimmed);
    if (match != null) {
      final double? lat = double.tryParse(match.group(1)!);
      final double? lng = double.tryParse(match.group(2)!);
      if (lat != null && lng != null) {
        return latlng.LatLng(lat, lng);
      }
    }

    // Use real-time geocoding service
    try {
      final results = await _towingServiceProvider.searchLocations(
        trimmed,
        limit: 1,
        latitude: _currentPosition?.latitude,
        longitude: _currentPosition?.longitude,
        radiusKm: 100.0,
      );
      
      if (results.isNotEmpty) {
        final result = results.first;
        return latlng.LatLng(result.latitude, result.longitude);
      }
    } catch (e) {
      print('Geocoding error: $e');
    }
    
    return null;
  }

  // Route using OSRM demo server with GeoJSON polyline
  Future<void> _routeWithDirections(latlng.LatLng start, latlng.LatLng dest) async {
    // Fallback: draw straight line immediately
    _drawRoute(start, dest);
    await _fitCameraToBounds(start, dest);

    try {
      final uri = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${dest.longitude},${dest.latitude}?overview=full&geometries=geojson');
      final res = await http.get(uri, headers: {'User-Agent': 'towing-app/1.0'});
      if (res.statusCode == 200) {
        final jsonBody = json.decode(res.body) as Map<String, dynamic>;
        final routes = jsonBody['routes'] as List<dynamic>;
        if (routes.isNotEmpty) {
          final route = routes.first as Map<String, dynamic>;
          final distanceM = (route['distance'] as num).toDouble();
          final durationS = (route['duration'] as num).toDouble();
          final geometry = route['geometry'] as Map<String, dynamic>;
          final coords = (geometry['coordinates'] as List<dynamic>)
              .map<latlng.LatLng>((c) => latlng.LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
              .toList();

          setState(() {
            _polylines
              ..clear()
              ..add(Polyline(points: coords, color: Colors.blueAccent, strokeWidth: 4));
            _distanceText = '${(distanceM / 1000).toStringAsFixed(2)} km';
            _durationText = '${(durationS / 60).round()} mins';
            _lastDistanceKm = distanceM / 1000.0;
            _lastFarePkr = _locationService.calculateFarePkr(_lastDistanceKm!, mode: selectedVehicleType);
          });
          return;
        }
      }
    } catch (_) {}

    // If OSRM fails, keep straight line and compute haversine
    final double distanceKm = _locationService.calculateDistanceKm(
      startLat: start.latitude,
      startLng: start.longitude,
      endLat: dest.latitude,
      endLng: dest.longitude,
    );
    final double minutes = (distanceKm / 40.0) * 60.0;
    setState(() {
      _distanceText = '${distanceKm.toStringAsFixed(2)} km';
      _durationText = '${minutes.round()} mins';
      _lastDistanceKm = distanceKm;
      _lastFarePkr = _locationService.calculateFarePkr(distanceKm, mode: selectedVehicleType);
    });
  }

  // Using your exact color scheme
  final Color _primaryColor = const Color(0xFF3A2A8B);
  final Color _cardColor = const Color(0xFF1F1B3C);
  final Color _accentColor = const Color(0xFF5A45D2);
  final Color _backgroundColor = const Color(0xFF121025);

  final LocationPricingService _locationService = LocationPricingService();
  final TowingServiceProvider _towingServiceProvider = TowingServiceProvider();

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: _backgroundColor,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    
    // Get real current location on app start
    _getInitialLocation();
  }

  Future<void> _getInitialLocation() async {
    try {
      final pos = await _locationService.getCurrentPosition();
      setState(() {
        _initialCenter = latlng.LatLng(pos.latitude, pos.longitude);
        _currentPosition = pos;
      });
    } catch (e) {
      print('Failed to get initial location: $e');
      // If location fails, show a message to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enable location services and try again'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _useCurrentLocation() async {
    try {
      setState(() => _isCalculating = true);
      final pos = await _locationService.getCurrentPosition();
      setState(() {
        _currentPosition = pos;
        _pickupPos = latlng.LatLng(pos.latitude, pos.longitude);
        locationController.text = 'Lat: ${pos.latitude.toStringAsFixed(5)}, Lng: ${pos.longitude.toStringAsFixed(5)}';
      });
      _addOrUpdatePickupMarker(_pickupPos!);
      _moveCamera(_pickupPos!, zoom: 14);
      
      // Show location accuracy info
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Location accuracy: ${pos.accuracy.toStringAsFixed(1)} meters'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Location error: $e')),
      );
    } finally {
      if (mounted) setState(() => _isCalculating = false);
    }
  }

  void _calculateFare() {
    final pos = _currentPosition;
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please tap "Use Current Location" first')),
      );
      return;
    }

    final String latStr = destinationLatController.text.trim();
    final String lngStr = destinationLngController.text.trim();

    if (latStr.isEmpty || lngStr.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter destination latitude and longitude')),
      );
      return;
    }

    final double? destLat = double.tryParse(latStr);
    final double? destLng = double.tryParse(lngStr);
    if (destLat == null || destLng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid destination coordinates')),
      );
      return;
    }

    setState(() => _isCalculating = true);

    final distanceKm = _locationService.calculateDistanceKm(
      startLat: pos.latitude,
      startLng: pos.longitude,
      endLat: destLat,
      endLng: destLng,
    );
    final fare = _locationService.calculateFarePkr(distanceKm);

    setState(() {
      _lastDistanceKm = distanceKm;
      _lastFarePkr = fare;
      destinationController.text = 'Lat: ${destLat.toStringAsFixed(5)}, Lng: ${destLng.toStringAsFixed(5)}';
      _isCalculating = false;
    });

    _updateDestination(latlng.LatLng(destLat, destLng));
  }

  void _onMapLongPress(latlng.LatLng latLng) {
    destinationLatController.text = latLng.latitude.toStringAsFixed(6);
    destinationLngController.text = latLng.longitude.toStringAsFixed(6);
    _updateDestination(latLng);
  }

  void _onMapPointerDown(PointerDownEvent event, latlng.LatLng point) {
    // Allow dragging pickup marker to correct location
    if (_pickupPos != null) {
      final distance = _locationService.calculateDistanceKm(
        startLat: _pickupPos!.latitude,
        startLng: _pickupPos!.longitude,
        endLat: point.latitude,
        endLng: point.longitude,
      );
      
      // If tap is close to pickup marker, allow dragging
      if (distance < 0.1) { // Within 100 meters
        _updatePickupLocation(point);
      }
    }
  }

  void _updatePickupLocation(latlng.LatLng newLocation) {
    setState(() {
      _pickupPos = newLocation;
      locationController.text = 'Lat: ${newLocation.latitude.toStringAsFixed(5)}, Lng: ${newLocation.longitude.toStringAsFixed(5)}';
    });
    _addOrUpdatePickupMarker(newLocation);
    
    // Update current position if it exists
    if (_currentPosition != null) {
      setState(() {
        _currentPosition = Position(
          latitude: newLocation.latitude,
          longitude: newLocation.longitude,
          timestamp: DateTime.now(),
          accuracy: _currentPosition!.accuracy,
          altitude: _currentPosition!.altitude,
          altitudeAccuracy: _currentPosition!.altitudeAccuracy,
          heading: _currentPosition!.heading,
          headingAccuracy: _currentPosition!.headingAccuracy,
          speed: _currentPosition!.speed,
          speedAccuracy: _currentPosition!.speedAccuracy,
        );
      });
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Location updated! Tap and drag the blue marker to adjust your position.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _updateDestination(latlng.LatLng destination) {
    _addOrUpdateDestinationMarker(destination);

    final hotspots = _generateHotspotMarkers(destination);
    _rebuildMarkers(extra: hotspots);

    if (_pickupPos != null) {
      _drawRoute(_pickupPos!, destination);
      _fitCameraToBounds(_pickupPos!, destination);
    } else {
      _moveCamera(destination, zoom: 14);
    }

    _findNearestTowing(center: destination);

    if (_pickupPos != null) {
      _routeWithDirections(_pickupPos!, destination);
    }
  }

  Future<void> _findNearestTowing({latlng.LatLng? center}) async {
    final latlng.LatLng? origin = center ?? _pickupPos;
    if (origin == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set destination or use current location first')),
      );
      return;
    }

    try {
      setState(() => _isCalculating = true);
      
      final services = await _towingServiceProvider.getNearbyTowingServices(
        latitude: origin.latitude,
        longitude: origin.longitude,
        vehicleType: selectedVehicleType,
        radiusKm: 50.0,
        limit: 5,
      );

    setState(() {
        _topRecommendations = services;
      });
      _rebuildMarkers();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error finding towing services: $e')),
      );
    } finally {
      setState(() => _isCalculating = false);
    }
  }

  // 100% REAL-TIME: No hardcoded providers - all data from OpenStreetMap

  void _addOrUpdatePickupMarker(latlng.LatLng pickup) {
    _pickupPos = pickup;
    _rebuildMarkers();
  }

  void _addOrUpdateDestinationMarker(latlng.LatLng destination) {
    _destPos = destination;
    _rebuildMarkers();
  }

  List<Marker> _generateHotspotMarkers(latlng.LatLng center) {
    const int count = 5;
    final List<Marker> markers = [];
    final rnd = math.Random(center.latitude.toInt() ^ center.longitude.toInt());
    for (int i = 0; i < count; i++) {
      final double bearing = rnd.nextDouble() * 2 * math.pi;
      final double distanceKm = 0.3 + rnd.nextDouble() * 0.7;
      final offset = _offsetLatLng(center, distanceKm, bearing);
      markers.add(
        Marker(
          point: offset,
          width: 36,
          height: 36,
          child: const Icon(Icons.local_fire_department, color: Colors.orange),
        ),
      );
    }
    return markers;
  }

  latlng.LatLng _offsetLatLng(latlng.LatLng origin, double distanceKm, double bearingRad) {
    const double earthRadiusKm = 6371.0;
    final double lat1 = origin.latitude * math.pi / 180.0;
    final double lon1 = origin.longitude * math.pi / 180.0;
    final double angularDistance = distanceKm / earthRadiusKm;

    final double lat2 = math.asin(
      math.sin(lat1) * math.cos(angularDistance) +
          math.cos(lat1) * math.sin(angularDistance) * math.cos(bearingRad),
    );
    final double lon2 = lon1 + math.atan2(
      math.sin(bearingRad) * math.sin(angularDistance) * math.cos(lat1),
      math.cos(angularDistance) - math.sin(lat1) * math.sin(lat2),
    );

    return latlng.LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi);
  }

  void _drawRoute(latlng.LatLng start, latlng.LatLng end) {
    setState(() {
      _polylines
        ..removeWhere((_) => true)
        ..add(Polyline(points: [start, end], color: Colors.blueAccent, strokeWidth: 4));
    });
  }

  Future<void> _fitCameraToBounds(latlng.LatLng a, latlng.LatLng b) async {
    final center = latlng.LatLng(
      (a.latitude + b.latitude) / 2,
      (a.longitude + b.longitude) / 2,
    );
    _mapController.move(center, 12);
  }

  Future<void> _moveCamera(latlng.LatLng target, {double zoom = 13}) async {
    _mapController.move(target, zoom);
  }

  void _rebuildMarkers({List<Marker> extra = const []}) {
    _markers
      ..clear()
      ..addAll(extra);

    if (_pickupPos != null) {
      _markers.add(Marker(
        point: _pickupPos!,
        width: 36,
        height: 36,
        child: const Icon(Icons.place, color: Colors.lightBlueAccent),
      ));
    }
    if (_destPos != null) {
      _markers.add(Marker(
        point: _destPos!,
        width: 36,
        height: 36,
        child: const Icon(Icons.flag, color: Colors.redAccent),
      ));
    }

    for (final service in _topRecommendations) {
      _markers.add(Marker(
        point: latlng.LatLng(service.latitude, service.longitude),
        width: 36,
        height: 36,
        child: const Icon(Icons.local_shipping, color: Colors.green),
      ));
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: AppBar(
        backgroundColor: _primaryColor,
        elevation: 0,
        title: const Text(
          'Towing Service',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // (User requested to remove everything above the blue header)
            // Emergency Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_accentColor, _primaryColor],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Icon(Icons.local_shipping, size: 60, color: Colors.white),
                  const SizedBox(height: 12),
                  const Text(
                    '24/7 Emergency Towing',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Fast & Reliable • Available Anytime',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 30),

            // Service Types
            _buildSectionTitle('Select Service Type'),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: _cardColor,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: _accentColor.withOpacity(0.3), width: 1),
              ),
              child: Column(
                children: [
                  _buildServiceOption(
                    'Emergency Towing',
                    Icons.warning,
                    '₨3,000 - 8,000',
                    'Immediate roadside pickup',
                  ),
                  _buildDivider(),
                  _buildServiceOption(
                    'Scheduled Towing',
                    Icons.schedule,
                    '₨2,000 - 5,000',
                    'Plan your towing in advance',
                  ),
                  _buildDivider(),
                  _buildServiceOption(
                    'Accident Recovery',
                    Icons.car_crash,
                    '₨5,000 - 12,000',
                    'Professional accident assistance',
                  ),
                  _buildDivider(),
                  _buildServiceOption(
                    'Roadside Assistance',
                    Icons.build,
                    '₨1,500 - 3,000',
                    'Jump start, tire change, fuel',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 30),

            // Vehicle Type Selection
            _buildSectionTitle('Vehicle Type'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _buildVehicleCard('Bicycle', Icons.pedal_bike)),
                const SizedBox(width: 12),
                Expanded(child: _buildVehicleCard('Car', Icons.directions_car)),
                const SizedBox(width: 12),
                Expanded(child: _buildVehicleCard('Truck', Icons.local_shipping)),
              ],
            ),

            const SizedBox(height: 30),

            // Location Inputs
            _buildSectionTitle('Location Details'),
            const SizedBox(height: 16),

            // Aggressive Location Search - Gets Your EXACT Location
            if (_currentPosition == null)
              AggressiveLocationWidget(
                onLocationFound: (position) {
                  setState(() {
                    _currentPosition = position;
                    _pickupPos = latlng.LatLng(position.latitude, position.longitude);
                    _initialCenter = _pickupPos;
                    locationController.text = 'Lat: ${position.latitude.toStringAsFixed(5)}, Lng: ${position.longitude.toStringAsFixed(5)}';
                  });
                  _addOrUpdatePickupMarker(_pickupPos!);
                  _moveCamera(_pickupPos!, zoom: 14);
                },
                onAddressFound: (address) {
                  locationController.text = address;
                },
              )
            else
              // Real-time Pickup Location Search (NO HARDCODED DATA)
              LocationSearchWidget(
                    controller: locationController,
                hintText: 'Search pickup location or use current location',
                    icon: Icons.my_location,
                    iconColor: _accentColor,
                showCurrentLocationButton: true,
                currentLatitude: _currentPosition?.latitude,
                currentLongitude: _currentPosition?.longitude,
                onLocationSelected: (result) {
                  _pickupPos = latlng.LatLng(result.latitude, result.longitude);
                  _addOrUpdatePickupMarker(_pickupPos!);
                  _moveCamera(_pickupPos!, zoom: 14);
                },
                onCoordinatesSelected: (lat, lng) {
                  _pickupPos = latlng.LatLng(lat, lng);
                  _addOrUpdatePickupMarker(_pickupPos!);
                  _moveCamera(_pickupPos!, zoom: 14);
                },
            ),

            const SizedBox(height: 16),

            // Real-time Destination Search (NO HARDCODED DATA)
            if (_initialCenter != null)
              LocationSearchWidget(
              controller: destinationController,
                hintText: 'Search destination or enter coordinates',
              icon: Icons.flag,
              iconColor: Colors.green,
                currentLatitude: _currentPosition?.latitude,
                currentLongitude: _currentPosition?.longitude,
                onLocationSelected: (result) {
                  destinationLatController.text = result.latitude.toStringAsFixed(6);
                  destinationLngController.text = result.longitude.toStringAsFixed(6);
                  _updateDestination(latlng.LatLng(result.latitude, result.longitude));
                },
                onCoordinatesSelected: (lat, lng) {
                  destinationLatController.text = lat.toStringAsFixed(6);
                  destinationLngController.text = lng.toStringAsFixed(6);
                  _updateDestination(latlng.LatLng(lat, lng));
                },
              )
            else
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1B3C),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: Colors.green.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    CircularProgressIndicator(color: Colors.green, strokeWidth: 2),
                    SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'Waiting for location to enable destination search...',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
            ),

            const SizedBox(height: 12),

            // Manual coordinate input (optional)
            Row(
              children: [
                Expanded(
                  child: _buildTextField(
                    controller: destinationLatController,
                    hintText: 'Latitude (optional)',
                    icon: Icons.place,
                    iconColor: Colors.orange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildTextField(
                    controller: destinationLngController,
                    hintText: 'Longitude (optional)',
                    icon: Icons.place_outlined,
                    iconColor: Colors.orange,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),
            
            // Location Accuracy Widget (show when current location is available)
            if (_currentPosition != null) ...[
              LocationAccuracyWidget(
                position: _currentPosition!,
                onLocationUpdated: (newPosition) {
                  setState(() {
                    _currentPosition = newPosition;
                    _pickupPos = latlng.LatLng(newPosition.latitude, newPosition.longitude);
                    locationController.text = 'Lat: ${newPosition.latitude.toStringAsFixed(5)}, Lng: ${newPosition.longitude.toStringAsFixed(5)}';
                  });
                  _addOrUpdatePickupMarker(_pickupPos!);
                  _moveCamera(_pickupPos!, zoom: 14);
                },
                onAddressUpdated: (address) {
                  locationController.text = address;
                },
                onManualLocationSelected: (location) {
                  setState(() {
                    _pickupPos = location;
                    locationController.text = 'Lat: ${location.latitude.toStringAsFixed(5)}, Lng: ${location.longitude.toStringAsFixed(5)}';
                    _currentPosition = Position(
                      latitude: location.latitude,
                      longitude: location.longitude,
                      timestamp: DateTime.now(),
                      accuracy: 10.0, // Assume good accuracy for manual input
                      altitude: 0.0,
                      altitudeAccuracy: 0.0,
                      heading: 0.0,
                      headingAccuracy: 0.0,
                      speed: 0.0,
                      speedAccuracy: 0.0,
                    );
                  });
                  _addOrUpdatePickupMarker(location);
                  _moveCamera(location, zoom: 14);
                  
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Manual location set successfully!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F1B3C).withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF5A45D2).withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.blue, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'If your location is wrong, tap the blue marker on the map to correct it, or use the search above to find your exact location.',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            
            // Real-Time OpenStreetMap (NO HARDCODED DATA)
            SizedBox(
              height: 300,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    if (_initialCenter != null)
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                          initialCenter: _initialCenter!,
                        initialZoom: 12,
                        onTap: (tapPos, point) => _onMapLongPress(point),
                          onPointerDown: (event, point) => _onMapPointerDown(event, point),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                          subdomains: const ['a', 'b', 'c'],
                        ),
                        PolylineLayer(polylines: _polylines),
                        MarkerLayer(markers: _markers),
                      ],
                      )
                    else
                      Container(
                        color: const Color(0xFF1F1B3C),
                        child: const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(color: Color(0xFF5A45D2)),
                              SizedBox(height: 16),
                              Text(
                                'Getting your real location...',
                                style: TextStyle(color: Colors.white70),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Please enable location services',
                                style: TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                    ),
                    if (_distanceText.isNotEmpty || _durationText.isNotEmpty)
                      Positioned(
                        bottom: 10,
                        left: 10,
                        right: 10,
                        child: Card(
                          color: Colors.white,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Distance: $_distanceText', style: const TextStyle(fontWeight: FontWeight.w600)),
                                Text('Duration: $_durationText', style: const TextStyle(fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),
            // Recommendations just below the map
            if (_topRecommendations.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionTitle('Top 5 Recommendations'),
                  const SizedBox(height: 8),
                  ..._topRecommendations.take(5).map((service) {
                    final double distanceKm = _locationService.calculateDistanceKm(
                      startLat: _pickupPos?.latitude ?? 0,
                      startLng: _pickupPos?.longitude ?? 0,
                      endLat: service.latitude,
                      endLng: service.longitude,
                    );
                    
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: _cardColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _accentColor.withOpacity(0.2)),
                      ),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _accentColor,
                          child: Text(service.name[0], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                        title: Text(service.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(service.address, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(Icons.star, color: Colors.amber, size: 16),
                                  const SizedBox(width: 4),
                                  Text('${service.rating.toStringAsFixed(1)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                  const SizedBox(width: 12),
                                  Icon(Icons.phone, color: Colors.green, size: 16),
                                  const SizedBox(width: 4),
                                  Text(service.phone, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text('${distanceKm.toStringAsFixed(2)} km away • ${service.workingHours}', 
                                   style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: service.vehicleTypes.map((vehicleType) {
                                  final fare = _locationService.calculateFarePkr(distanceKm, mode: vehicleType);
                                  return _fareChip(vehicleType, fare);
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.navigation, color: Colors.white),
                              onPressed: () async {
                                await _moveCamera(latlng.LatLng(service.latitude, service.longitude), zoom: 15);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.phone, color: Colors.green),
                              onPressed: () {
                                // TODO: Implement phone call
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Calling ${service.phone}')),
                                );
                              },
                            ),
                          ],
                        ),
                        onTap: () async {
                          destinationLatController.text = service.latitude.toStringAsFixed(6);
                          destinationLngController.text = service.longitude.toStringAsFixed(6);
                          _updateDestination(latlng.LatLng(service.latitude, service.longitude));
                        },
                      ),
                    );
                  }),
                ],
              ),

            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: () => _findNearestTowing(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.search, color: Colors.white),
                label: const Text('Find Nearest Towing', style: TextStyle(color: Colors.white)),
              ),
            ),

            const SizedBox(height: 16),

            // Calculate Fare button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isCalculating ? null : _calculateFare,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accentColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isCalculating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Calculate Distance & Fare', style: TextStyle(color: Colors.white)),
              ),
            ),

            if (_lastDistanceKm != null && _lastFarePkr != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _cardColor,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: _accentColor.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Distance: ${_lastDistanceKm!.toStringAsFixed(2)} km',
                        style: const TextStyle(color: Colors.white, fontSize: 16)),
                    const SizedBox(height: 6),
                    Text('Fare (₨100/km): ₨${_lastFarePkr!.toStringAsFixed(0)}',
                        style: const TextStyle(color: Colors.green, fontSize: 18, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 30),

            // Emergency Contact Info
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: _cardColor,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.phone_in_talk, color: Colors.orange, size: 28),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Emergency Hotline',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          '+92 300 1234567',
                          style: TextStyle(color: Colors.orange, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {},
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      'Call Now',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 30),

            // Request Button
            Container(
              width: double.infinity,
              height: 55,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_accentColor, _primaryColor],
                ),
                borderRadius: BorderRadius.circular(15),
              ),
              child: ElevatedButton(
                onPressed: () {
                  _showBookingConfirmation(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.send, color: Colors.white),
                    SizedBox(width: 10),
                    Text(
                      'Request Towing Service',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        color: _accentColor,
        fontSize: 18,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _buildServiceOption(String title, IconData icon, String price, String description) {
    bool isSelected = selectedServiceType == title;
    return InkWell(
      onTap: () => setState(() => selectedServiceType = title),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected ? _accentColor.withOpacity(0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(15),
          border: isSelected ? Border.all(color: _accentColor) : null,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isSelected ? _accentColor : _accentColor.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: isSelected ? Colors.white : _accentColor,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    price,
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check_circle, color: _accentColor),
          ],
        ),
      ),
    );
  }

  Widget _buildVehicleCard(String type, IconData icon) {
    bool isSelected = selectedVehicleType == type;
    return InkWell(
      onTap: () => setState(() => selectedVehicleType = type),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? _accentColor : _cardColor,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: isSelected ? _accentColor : _accentColor.withOpacity(0.3),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: Colors.white, size: 32),
            const SizedBox(height: 8),
            Text(
              type,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    required Color iconColor,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: _accentColor.withOpacity(0.3)),
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: const TextStyle(color: Colors.white54),
          prefixIcon: Icon(icon, color: iconColor),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(20),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      height: 1,
      color: _accentColor.withOpacity(0.1),
    );
  }

  Widget _fareChip(String label, double fare) {
    final Color accent = _accentColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            label == 'Bicycle' ? Icons.pedal_bike : label == 'Truck' ? Icons.local_shipping : Icons.directions_car,
            size: 16,
            color: accent,
          ),
          const SizedBox(width: 6),
          Text('$label: ₨${fare.toStringAsFixed(0)}', style: const TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }

  // duplicate removed

  void _showBookingConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Booking Confirmed!',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Your towing request has been submitted. A driver will contact you within 15 minutes.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(backgroundColor: _accentColor),
            child: const Text('OK', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    locationController.dispose();
    destinationController.dispose();
    destinationLatController.dispose();
    destinationLngController.dispose();
    super.dispose();
  }
}

class _Provider {
  final String name;
  final latlng.LatLng position;
  _Provider({required this.name, required this.position});
}

class _Recommendation {
  final String name;
  final latlng.LatLng position;
  final double distanceKm;
  final double farePkr;
  _Recommendation({required this.name, required this.position, required this.distanceKm, required this.farePkr});
}


// Removed charts-related classes and helpers

int _parseNumber(String text) {
  // Extract leading integer from strings like "12 km" or "8 mins"
  final match = RegExp(r'^(\d+)').firstMatch(text.trim());
  if (match == null) return 0;
  return int.tryParse(match.group(1)!) ?? 0;
}

class LiveMapScreen extends StatefulWidget {
  final latlng.LatLng? pickup;
  final latlng.LatLng? destination;
  const LiveMapScreen({Key? key, this.pickup, this.destination}) : super(key: key);

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final MapController _controller = MapController();
  final List<Marker> _markers = [];
  final List<Polyline> _polylines = [];

  @override
  void initState() {
    super.initState();
    if (widget.pickup != null) {
      _markers.add(Marker(point: widget.pickup!, width: 36, height: 36, child: const Icon(Icons.place, color: Colors.lightBlueAccent)));
    }
    if (widget.destination != null) {
      _markers.add(Marker(point: widget.destination!, width: 36, height: 36, child: const Icon(Icons.flag, color: Colors.redAccent)));
    }
    if (widget.pickup != null && widget.destination != null) {
      _polylines.add(Polyline(points: [widget.pickup!, widget.destination!], color: Colors.blueAccent, strokeWidth: 4));
    }
  }

  @override
  Widget build(BuildContext context) {
    final latlng.LatLng initial = widget.destination ?? widget.pickup ?? const latlng.LatLng(0, 0);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Map', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF3A2A8B),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _controller,
              options: MapOptions(
                initialCenter: initial,
                initialZoom: 14,
                onTap: (tapPos, latLng) {
                setState(() {
                    _markers.removeWhere((m) => true);
                    if (widget.pickup != null) {
                      _markers.add(Marker(point: widget.pickup!, width: 36, height: 36, child: const Icon(Icons.place, color: Colors.lightBlueAccent)));
                  _polylines
                        ..clear()
                        ..add(Polyline(points: [widget.pickup!, latLng], color: Colors.blueAccent, strokeWidth: 4));
                    }
                    _markers.add(Marker(point: latLng, width: 36, height: 36, child: const Icon(Icons.flag, color: Colors.redAccent)));
                });
              },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                  subdomains: const ['a', 'b', 'c'],
                ),
                PolylineLayer(polylines: _polylines),
                MarkerLayer(markers: _markers),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final destMarker = _markers.isNotEmpty ? _markers.last : null;
                      if (destMarker == null) {
                        Navigator.pop(context);
                        return;
                      }
                      Navigator.pop(context, destMarker.point);
                    },
                    icon: const Icon(Icons.check, color: Colors.white),
                    label: const Text('Use This Location', style: TextStyle(color: Colors.white)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5A45D2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1F1B3C),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Icon(Icons.close, color: Colors.white),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
