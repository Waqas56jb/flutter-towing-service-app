import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  // Using your exact color scheme
  final Color _primaryColor = const Color(0xFF3A2A8B); // Dark purple
  final Color _cardColor = const Color(0xFF1F1B3C); // Darker purple for cards
  final Color _accentColor = const Color(0xFF5A45D2); // Lighter purple for accents
  final Color _backgroundColor = const Color(0xFF121025); // Very dark purple background

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
                Expanded(child: _buildVehicleCard('Car', Icons.directions_car)),
                const SizedBox(width: 12),
                Expanded(child: _buildVehicleCard('SUV/Truck', Icons.local_shipping)),
                const SizedBox(width: 12),
                Expanded(child: _buildVehicleCard('Motorcycle', Icons.motorcycle)),
              ],
            ),

            const SizedBox(height: 30),

            // Location Inputs
            _buildSectionTitle('Location Details'),
            const SizedBox(height: 16),

            // Pickup Location
            _buildTextField(
              controller: locationController,
              hintText: 'Enter pickup location',
              icon: Icons.my_location,
              iconColor: _accentColor,
            ),

            const SizedBox(height: 16),

            // Destination
            _buildTextField(
              controller: destinationController,
              hintText: 'Where should we tow your vehicle?',
              icon: Icons.flag,
              iconColor: Colors.green,
            ),

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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
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
                    onPressed: () {
                      // Make phone call
                    },
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
    super.dispose();
  }
}