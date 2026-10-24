// Stand-in for the phone app's feedback/motion.dart: the two types packets.dart reads.

class Vector {
  const Vector(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;
}

class Motion {
  const Motion(this.accel, this.gyro);

  final Vector accel;
  final Vector gyro;
}
