package Slic3T::Skein;
use Moo;

use Config;
use File::Basename qw(basename fileparse);
use Slic3T::Geometry qw(PI unscale);
use Time::HiRes qw(gettimeofday tv_interval);

# full path (relative or absolute) to the input file
has 'input_file'    => (is => 'ro', required => 1);

# full path (relative or absolute) to the output file; it may contain
# formatting variables like [layer_height] etc.
has 'output_file'   => (is => 'rw', required => 0);

has 'status_cb'     => (is => 'rw', required => 0, default => sub { sub {} });
has 'processing_time' => (is => 'rw', required => 0);

sub slice_input {
    my $self = shift;
    
    my $print;
    if ($self->input_file =~ /\.stl$/i) {
        my $mesh = Slic3T::Format::STL->read_file($self->input_file);
        $mesh->check_manifoldness;
        $print = Slic3T::Print->new_from_mesh($mesh);
    } elsif ( $self->input_file =~ /\.amf(\.xml)?$/i) {
        my ($materials, $meshes_by_material) = Slic3T::Format::AMF->read_file($self->input_file);
        $_->check_manifoldness for values %$meshes_by_material;
        $print = Slic3T::Print->new_from_mesh($meshes_by_material->{_} || +(values %$meshes_by_material)[0]);
    } else {
        die "Input file must have .stl or .amf(.xml) extension\n";
    }
}

sub go {
    my $self = shift;
    my $t0 = [gettimeofday];
    
    # skein the STL into layers
    # each layer has surfaces with holes
    $self->status_cb->(5, "Processing input file " . $self->input_file);    
    $self->status_cb->(10, "Processing triangulated mesh");
    my $print = $self->slice_input;
    
    # make perimeters
    # this will add a set of extrusion loops to each layer
    # as well as generate infill boundaries
    $self->status_cb->(20, "Generating perimeters");
    {
        my $perimeter_maker = Slic3T::Perimeter->new;
        $perimeter_maker->make_perimeter($_) for @{$print->layers};
    }
    
    # this will clip $layer->surfaces to the infill boundaries 
    # and split them in top/bottom/internal surfaces;
    $self->status_cb->(30, "Detecting solid surfaces");
    $print->detect_surfaces_type;
    
    # decide what surfaces are to be filled
    $self->status_cb->(35, "Preparing infill surfaces");
    $_->prepare_fill_surfaces for @{$print->layers};
    
    # this will remove unprintable surfaces
    # (those that are too tight for extrusion)
    $self->status_cb->(40, "Cleaning up");
    $_->remove_small_surfaces for @{$print->layers};
    
    # this will detect bridges and reverse bridges
    # and rearrange top/bottom/internal surfaces
    $self->status_cb->(45, "Detect bridges");
    $_->process_bridges for @{$print->layers};
    
    # this will remove unprintable perimeter loops
    # (those that are too tight for extrusion)
    $self->status_cb->(50, "Cleaning up the perimeters");
    $_->remove_small_perimeters for @{$print->layers};
    
    # detect which fill surfaces are near external layers
    # they will be split in internal and internal-solid surfaces
    $self->status_cb->(60, "Generating horizontal shells");
    $print->discover_horizontal_shells;
    
    # free memory
    @{$_->surfaces} = () for @{$print->layers};
    
    # combine fill surfaces to honor the "infill every N layers" option
    $self->status_cb->(70, "Combining infill");
    $print->infill_every_layers;
    
    # this will generate extrusion paths for each layer
    $self->status_cb->(80, "Infilling layers");
    {
        my $fill_maker = Slic3T::Fill->new('print' => $print);
        
        Slic3T::parallelize(
            items => [ 0..($print->layer_count-1) ],
            thread_cb => sub {
                my $q = shift;
                $Slic3T::Geometry::Clipper::clipper = Math::Clipper->new;
                my $fills = {};
                while (defined (my $layer_id = $q->dequeue)) {
                    $fills->{$layer_id} = [ $fill_maker->make_fill($print->layers->[$layer_id]) ];
                }
                return $fills;
            },
            collect_cb => sub {
                my $fills = shift;
                foreach my $layer_id (keys %$fills) {
                    @{$print->layers->[$layer_id]->fills} = @{$fills->{$layer_id}};
                }
            },
            no_threads_cb => sub {
                foreach my $layer (@{$print->layers}) {
                    @{$layer->fills} = $fill_maker->make_fill($layer);
                }
            },
        );
    }
    
    # generate support material
    if ($Slic3T::support_material) {
        $self->status_cb->(85, "Generating support material");
        $print->generate_support_material;
    }
    
    # free memory (note that support material needs fill_surfaces)
    @{$_->fill_surfaces} = () for @{$print->layers};
    
    # make skirt
    $self->status_cb->(88, "Generating skirt");
    $print->extrude_skirt;
    
    # output everything to a G-code file
    my $output_file = $self->expanded_output_filepath;
    $self->status_cb->(90, "Exporting G-code to $output_file");
    $print->export_gcode($output_file);
    
    # run post-processing scripts
    if (@$Slic3T::post_process) {
        $self->status_cb->(95, "Running post-processing scripts");
        for (@$Slic3T::post_process) {
            Slic3T::debugf "  '%s' '%s'\n", $_, $output_file;
            system($_, $output_file);
        }
    }
    
    # output some statistics
    $self->processing_time(tv_interval($t0));
    printf "Done. Process took %d minutes and %.3f seconds\n", 
        int($self->processing_time/60),
        $self->processing_time - int($self->processing_time/60)*60;
    
    # TODO: more statistics!
    printf "Filament required: %.1fmm (%.1fcm3)\n",
        $print->total_extrusion_length, $print->total_extrusion_volume;
}

sub export_svg {
    my $self = shift;
    
    my $print = $self->slice_input;
    my $output_file = $self->expanded_output_filepath;
    $output_file =~ s/\.gcode$/.svg/i;
    
    open my $fh, ">", $output_file or die "Failed to open $output_file for writing\n";
    print "Exporting to $output_file...";
    print $fh sprintf <<"EOF", unscale($print->total_x_length), unscale($print->total_y_length);
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.0//EN" "http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd">
<svg width="%s" height="%s" xmlns="http://www.w3.org/2000/svg" xmlns:svg="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:slic3r="http://slic3r.org/namespaces/slic3r">
  <!-- 
  Generated using Slic3T $Slic3T::VERSION
   -->
EOF
    
    my $print_polygon = sub {
        my ($polygon, $type) = @_;
        printf $fh qq{    <polygon slic3T:type="%s" points="%s" style="fill: %s" />\n},
            $type, (join ' ', map { join ',', map unscale $_, @$_ } @$polygon),
            ($type eq 'contour' ? 'black' : 'white');
    };
    
    foreach my $layer (@{$print->layers}) {
        printf $fh qq{  <g id="layer%d" slic3T:z="%s">\n}, $layer->id, unscale $layer->slice_z;
        # sort slices so that the outermost ones come first
        my @slices = sort { $a->expolygon->contour->encloses_point($b->expolygon->contour->[0]) ? 0 : 1 } @{$layer->slices};
        
        foreach my $copy (@{$print->copies}) {
            foreach my $slice (@slices) {
                my $expolygon = $slice->expolygon->clone;
                $expolygon->translate(@$copy);
                $print_polygon->($expolygon->contour, 'contour');
                $print_polygon->($_, 'hole') for $expolygon->holes;
            }
        }
        print $fh qq{  </g>\n};
    }
    
    print $fh "</svg>\n";
    close $fh;
    print "Done.\n";
}

# this method will return the value of $self->output_file after expanding its
# format variables with their values
sub expanded_output_filepath {
    my $self = shift;
    
    my $path = $self->output_file;
    
    # if no explicit output file was defined, we take the input
    # file directory and append the specified filename format
    $path ||= (fileparse($self->input_file))[1] . $Slic3T::output_filename_format;
    
    my $input_filename = my $input_filename_base = basename($self->input_file);
    $input_filename_base =~ s/\.(?:stl|amf(?:\.xml)?)$//i;
    
    return Slic3T::Config->replace_options($path, {
        input_filename      => $input_filename,
        input_filename_base => $input_filename_base,
    });
}

1;
