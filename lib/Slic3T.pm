package Slic3T;

# Copyright holder: Alessandro Ranellucci
# This application is licensed under the GNU Affero General Public License, version 3

use strict;
use warnings;
require v5.10;

our $VERSION = "0.7.2c";

our $debug = 0;
sub debugf {
    printf @_ if $debug;
}

use Config;
use Slic3T::Config;
use Slic3T::ExPolygon;
use Slic3T::Extruder;
use Slic3T::ExtrusionLoop;
use Slic3T::ExtrusionPath;
use Slic3T::ExtrusionPath::Arc;
use Slic3T::ExtrusionPath::Collection;
use Slic3T::Fill;
use Slic3T::Format::AMF;
use Slic3T::Format::STL;
use Slic3T::Geometry qw(PI);
use Slic3T::Layer;
use Slic3T::Line;
use Slic3T::Perimeter;
use Slic3T::Point;
use Slic3T::Polygon;
use Slic3T::Polyline;
use Slic3T::Print;
use Slic3T::Skein;
use Slic3T::Surface;
use Slic3T::TriangleMesh;
use Slic3T::TriangleMesh::IntersectionLine;

our $have_threads       = $Config{useithreads} && eval "use threads; use Thread::Queue; 1";
our $threads            = $have_threads ? 4 : undef;

# miscellaneous options
our $notes              = '';

# output options
our $output_filename_format = '[input_filename_base].gcode';
our $post_process       = [];

# printer options
our $nozzle_diameter    = 0.45;
our $print_center       = [50,50];  # object will be centered around this point
our $z_offset           = 0;
our $gcode_flavor       = 'reprap';
our $use_relative_e_distances = 1;
our $extrusion_axis     = 'E';
our $gcode_arcs         = 0;
our $g0                 = 0;
our $gcode_comments     = 0;

# filament options
our $filament_diameter  = 3;    # mm
our $extrusion_multiplier = 1;
our $temperature        = 190;
our $first_layer_temperature = 200;
our $bed_temperature    = 0;
our $first_layer_bed_temperature;

# speed options
our $travel_speed           = 150;  # mm/s
our $perimeter_speed        = 45;   # mm/s
our $small_perimeter_speed  = 45;   # mm/s
our $infill_speed           = 45;   # mm/s
our $solid_infill_speed     = 45;   # mm/s
our $bridge_speed           = 18;   # mm/s
our $bottom_layer_speed_ratio   = 0.6;

# acceleration options
our $acceleration           = 0;
our $perimeter_acceleration = 25;   # mm/s^2
our $infill_acceleration    = 50;   # mm/s^2

# accuracy options
our $scaling_factor         = 0.00000001;
our $small_perimeter_area   = ((6.5 / $scaling_factor)**2)*PI;
our $layer_height           = 0.15;
our $first_layer_height_ratio = 1.33;
our $infill_every_layers    = 1;

# flow options
our $extrusion_width_ratio  = 3.4;
our $bridge_flow_ratio      = 1;
our $overlap_factor         = 0.5;
our $flow_width;
our $min_flow_spacing;
our $flow_spacing;

# print options
our $perimeters         = 4;
our $solid_layers       = 7;
our $fill_pattern       = 'honeycomb';
our $solid_fill_pattern = 'rectilinear';
our $fill_density       = 0.4;  # 1 = 100%
our $fill_angle         = 45;
our $support_material   = 0;
our $support_material_tool = 0;
our $start_gcode = <<"START";
M109 S[first_layer_temperature] ;preheat hotend before homing
G28 Z0 ; home Z
G1 F6000 Z2 ; lift nozzle before movng to center
G1 X50 Y50 F6000 ; move to center
G1 Z0
START
our $end_gcode = <<"END";
M104 S0 ; turn off temperature
G28 X0  ; home X axis
M84     ; disable motors
END
our $layer_gcode        = '';

# retraction options
our $retract_length         = 5;    # mm
our $retract_restart_extra  = 0;    # mm
our $retract_speed          = 1000;   # mm/s
our $retract_before_travel  = 2;    # mm
our $retract_lift           = 0.15;    # mm

# cooling options
our $cooling                = 1;
our $min_fan_speed          = 80;
our $max_fan_speed          = 100;
our $bridge_fan_speed       = 100;
our $fan_below_layer_time   = 20;
our $slowdown_below_layer_time = 7;
our $min_print_speed        = 10;
our $disable_fan_first_layers = 0;
our $fan_always_on          = 1;

# skirt options
our $skirts             = 3;
our $skirt_distance     = 6;    # mm
our $skirt_height       = 1;    # layers

# transform options
our $scale              = 1;
our $rotate             = 0;
our $duplicate_mode     = 'no';
our $duplicate          = 1;
our $bed_size           = [100,100];
our $duplicate_grid     = [1,1];
our $duplicate_distance = 3;    # mm

sub parallelize {
    my %params = @_;
    
    if (!$params{disable} && $Slic3T::have_threads && $Slic3T::threads > 1) {
        my $q = Thread::Queue->new;
        $q->enqueue(@{ $params{items} }, (map undef, 1..$Slic3T::threads));
        
        my $thread_cb = sub { $params{thread_cb}->($q) };
        foreach my $th (map threads->create($thread_cb), 1..$Slic3T::threads) {
            $params{collect_cb}->($th->join);
        }
    } else {
        $params{no_threads_cb}->();
    }
}

1;
