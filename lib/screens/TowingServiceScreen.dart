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
// import 'package:charts_flutter/flutter.dart' as charts;
const latlng.LatLng kFallbackCenter = latlng.LatLng(31.5204, 74.3587);

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
  latlng.LatLng _initialCenter = kFallbackCenter;

  latlng.LatLng? _pickupPos;
  latlng.LatLng? _destPos;

  List<_Recommendation> _topRecommendations = [];

  // Live route stats
  String _distanceText = '';
  String _durationText = '';

  final Map<String, latlng.LatLng> _localPlaces = const {
    'lahore': latlng.LatLng(31.5204, 74.3587),
    'karachi': latlng.LatLng(24.8607, 67.0011),
    'islamabad': latlng.LatLng(33.6844, 73.0479),
    'rawalpindi': latlng.LatLng(33.5651, 73.0169),
    'multan': latlng.LatLng(30.1575, 71.5249),
  };

  Future<void> _handleDestinationQuery(String query) async {
    final q = query.trim().toLowerCase();
    if (q.contains('nearest') && (q.contains('tow') || q.contains('towing'))) {
      latlng.LatLng center;
      if (_currentPosition != null) {
        center = latlng.LatLng(_currentPosition!.latitude, _currentPosition!.longitude);
      } else {
        center = kFallbackCenter;
      }
      final providers = _generateNearbyProviders(center, count: 12);
      providers.sort((a, b) {
        final da = _locationService.calculateDistanceKm(
          startLat: center.latitude,
          startLng: center.longitude,
          endLat: a.position.latitude,
          endLng: a.position.longitude,
        );
        final db = _locationService.calculateDistanceKm(
          startLat: center.latitude,
          startLng: center.longitude,
          endLat: b.position.latitude,
          endLng: b.position.longitude,
        );
        return da.compareTo(db);
      });
      if (providers.isNotEmpty) {
        final nearest = providers.first;
        destinationController.text = nearest.name;
        destinationLatController.text = nearest.position.latitude.toStringAsFixed(6);
        destinationLngController.text = nearest.position.longitude.toStringAsFixed(6);
        _updateDestination(nearest.position);
        if (_currentPosition != null) {
          await _routeWithDirections(latlng.LatLng(_currentPosition!.latitude, _currentPosition!.longitude), nearest.position);
        } else {
          await _moveCamera(nearest.position, zoom: 14);
        }
      }
      return;
    }

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
        const SnackBar(content: Text('Destination not recognized. Try city name or "nearest towing service"')),
      );
    }
  }

  // Geocode via coordinates, local map, then Nominatim worldwide
  Future<latlng.LatLng?> _geocodeAddress(String query) async {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    final RegExp coordRe = RegExp(r'^\s*([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*$');
    final match = coordRe.firstMatch(trimmed);
    if (match != null) {
      final double? lat = double.tryParse(match.group(1)!);
      final double? lng = double.tryParse(match.group(2)!);
      if (lat != null && lng != null) {
        return latlng.LatLng(lat, lng);
      }
    }

    final key = trimmed.toLowerCase();
    if (_localPlaces.containsKey(key)) {
      return _localPlaces[key];
    }

    // Nominatim global geocoding
    try {
      final uri = Uri.parse('https://nominatim.openstreetmap.org/search?q=${Uri.encodeQueryComponent(trimmed)}&format=json&limit=1');
      final res = await http.get(uri, headers: {
        'User-Agent': 'towing-app/1.0 (contact: example@example.com)'
      });
      if (res.statusCode == 200) {
        final List data = json.decode(res.body) as List;
        if (data.isNotEmpty) {
          final m = data.first as Map<String, dynamic>;
          final double lat = double.parse(m['lat'] as String);
          final double lon = double.parse(m['lon'] as String);
          return latlng.LatLng(lat, lon);
        }
      }
    } catch (_) {}
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

    final providers = _generateNearbyProviders(origin, count: 12);

    final withDistance = providers.map((p) {
      final distanceKm = _locationService.calculateDistanceKm(
        startLat: origin.latitude,
        startLng: origin.longitude,
        endLat: p.position.latitude,
        endLng: p.position.longitude,
      );
      final fare = _locationService.calculateFarePkr(distanceKm, mode: selectedVehicleType);
      return _Recommendation(name: p.name, position: p.position, distanceKm: distanceKm, farePkr: fare);
    }).toList();

    withDistance.sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
    final top5 = withDistance.take(5).toList();

    setState(() {
      _topRecommendations = top5;
    });
    _rebuildMarkers();
  }

  List<_Provider> _generateNearbyProviders(latlng.LatLng center, {int count = 10}) {
    final rnd = math.Random(center.latitude.toInt() ^ center.longitude.toInt() ^ 42);
    final List<_Provider> providers = [];
    for (int i = 0; i < count; i++) {
      final double bearing = rnd.nextDouble() * 2 * math.pi;
      final double distanceKm = 0.5 + rnd.nextDouble() * 5.0;
      final pos = _offsetLatLng(center, distanceKm, bearing);
      providers.add(_Provider(name: 'TowPoint ${i + 1}', position: pos));
    }
    return providers;
  }

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

    for (final r in _topRecommendations) {
      _markers.add(Marker(
        point: r.position,
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

            // Pickup Location + button
            Row(
              children: [
                Expanded(
                  child: _buildTextField(
                    controller: locationController,
                    hintText: 'Pickup (tap Use Current Location)',
                    icon: Icons.my_location,
                    iconColor: _accentColor,
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _isCalculating ? null : _useCurrentLocation,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accentColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Use Current', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Destination free text (optional)
            _buildTextField(
              controller: destinationController,
              hintText: 'Destination (optional label)',
              icon: Icons.flag,
              iconColor: Colors.green,
            ),

            const SizedBox(height: 12),

            // Destination lat/lng
            Row(
              children: [
                Expanded(
                  child: _buildTextField(
                    controller: destinationLatController,
                    hintText: 'Dest Latitude',
                    icon: Icons.place,
                    iconColor: Colors.orange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildTextField(
                    controller: destinationLngController,
                    hintText: 'Dest Longitude',
                    icon: Icons.place_outlined,
                    iconColor: Colors.orange,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),
            // OpenStreetMap moved here inside Location Details
            SizedBox(
              height: 300,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _initialCenter,
                        initialZoom: 12,
                        onTap: (tapPos, point) => _onMapLongPress(point),
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
                  ..._topRecommendations.take(5).map((r) {
                    final double fareBike = _locationService.calculateFarePkr(r.distanceKm, mode: 'Bicycle');
                    final double fareCar = _locationService.calculateFarePkr(r.distanceKm, mode: 'Car');
                    final double fareTruck = _locationService.calculateFarePkr(r.distanceKm, mode: 'Truck');
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: _cardColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _accentColor.withOpacity(0.2)),
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.local_shipping, color: Colors.green),
                        title: Text(r.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${r.distanceKm.toStringAsFixed(2)} km away', style: const TextStyle(color: Colors.white70)),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  _fareChip('Bicycle', fareBike),
                                  _fareChip('Car', fareCar),
                                  _fareChip('Truck', fareTruck),
                                ],
                              ),
                            ],
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.navigation, color: Colors.white),
                          onPressed: () async {
                            await _moveCamera(r.position, zoom: 15);
                          },
                        ),
                        onTap: () async {
                          destinationLatController.text = r.position.latitude.toStringAsFixed(6);
                          destinationLngController.text = r.position.longitude.toStringAsFixed(6);
                          _updateDestination(r.position);
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
    final latlng.LatLng initial = widget.destination ?? widget.pickup ?? kFallbackCenter;
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
