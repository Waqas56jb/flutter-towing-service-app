class Mechanic {
  final int? id; // Database ID (null when creating new mechanic)
  final String name;
  final String phone;
  final String email;
  final String address;
  final int yearsOfExperience;
  final String specialty;
  final String status; // Added status field
  final DateTime createdAt;

  Mechanic({
    this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.address,
    required this.yearsOfExperience,
    required this.specialty,
    this.status = 'pending', // Always set default value to 'pending'
    DateTime? createdAt,
  }) : this.createdAt = createdAt ?? DateTime.now();

  // Convert Mechanic object to a Map for database operations
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'phone': phone,
      'email': email,
      'address': address,
      'years_of_experience': yearsOfExperience,
      'specialty': specialty,
      'status': status, // Added status to the map
      'created_at': createdAt.toIso8601String(),
    };
  }

  // Create a Mechanic object from a database Map
  factory Mechanic.fromMap(Map<String, dynamic> map) {
    return Mechanic(
      id: map['id'],
      name: map['name'],
      phone: map['phone'],
      email: map['email'],
      address: map['address'],
      yearsOfExperience: map['years_of_experience'],
      specialty: map['specialty'],
      status: map['status'], // Added status from the map
      createdAt: DateTime.parse(map['created_at']),
    );
  }
}
