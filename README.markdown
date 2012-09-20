_Q: Oh cool, a new RepRap slicer?_

A: Yes.

# Slic3T

## What's it?

Slic3T is an STL-to-GCODE translator for RepRap 3D printers, aiming to
be a modern and fast alternative to Skeinforge.

See the [project homepage](http://Slic3T.org/) at Slic3T.org
for more information.

## What language is it written in?

Proudly Perl, with some parts in C++.
If you're wondering why Perl, see http://xkcd.com/224/

## What's its current status?

Slic3T current key features are:

* multi-platform (Linux/Mac/Win) and packaged as standalone-app with no dependencies required;
* easy configuration/calibration;
* read binary and ASCII STL files as well as AMF;
* powerful command line interface;
* easy GUI;
* multithreaded;
* multiple infill patterns, with customizable density and angle;
* retraction;
* skirt;
* infill every N layers (like the "Skin" plugin for Skeinforge);
* detect optimal infill direction for bridges;
* save configuration profiles;
* center print around bed center point;
* multiple solid layers near horizontal external surfaces;
* ability to scale, rotate and duplicate input object;
* customizable initial and final G-code;
* support material;
* cooling and fan control;
* use different speed for bottom layer and perimeters.

Experimental features include:

* generation of G2/G3 commands for native arcs;
* G0 commands for fast retraction.

Roadmap includes the following goals:

* output some statistics;
* support material for internal perimeters;
* new and better GUI;
* more fill patterns.

## Is it usable already? Any known limitation?

Sure, it's very usable. Remember that:

* it only works well with manifold and clean models (check them with Meshlab or Netfabb or http://cloud.netfabb.com/).

## How to install?

It's very easy. See the [project homepage](http://Slic3T.org/)
for instructions and links to the precompiled packages.

## Can I help?

Sure! Send patches and/or drop me a line at aar@cpan.org. You can also 
find me in #reprap on FreeNode with the nickname _Sound_.

## What's Slic3T license?

Slic3T is licensed under the _GNU Affero General Public License, version 3_.
The author is Alessandro Ranellucci (me).

## How can I invoke slic3T.pl using the command line?

    Usage: slic3T.pl [ OPTIONS ] file.stl
    
        --help              Output this usage screen and exit
        --save <file>       Save configuration to the specified file
        --load <file>       Load configuration from the specified file. It can be used 
                            more than once to load options from multiple files.
        -o, --output <file> File to output gcode to (by default, the file will be saved
                            into the same directory as the input file using the 
                            --output-filename-format to generate the filename)
        -j, --threads <num> Number of threads to use (1+, default: 4) 
      
      Output options:
        --output-filename-format
                            Output file name format; all config options enclosed in brackets
                            will be replaced by their values, as well as [input_filename_base]
                            and [input_filename] (default: [input_filename_base].gcode)
        --post-process      Generated G-code will be processed with the supplied script;
                            call this more than once to process through multiple scripts.
        --export-svg        Export a SVG file containing slices instead of G-code.
      
      Printer options:
        --nozzle-diameter   Diameter of nozzle in mm (default: 0.5)
        --print-center      Coordinates in mm of the point to center the print around 
        --z-offset          Additional height in mm to add to vertical coordinates
        --gcode-flavor      The type of G-code to generate (reprap/teacup/makerbot/mach3/no-extrusion,
                            default: reprap)
        --use-relative-e-distances Enable this to get relative E values
        --gcode-arcs        Use G2/G3 commands for native arcs (experimental, not supported
                            by all firmwares)
        --g0                Use G0 commands for retraction (experimental, not supported by all
                            firmwares)
        --gcode-comments    Make G-code verbose by adding comments
        
      Filament options:
        --filament-diameter Diameter in mm of your raw filament
        --extrusion-multiplier
                            Change this to alter the amount of plastic extruded. There should be
                            very little need to change this value, which is only useful to 
                            compensate for filament packing (default: 1)
        --temperature       Extrusion temperature in degree Celsius, set 0 to disable
        --first-layer-temperature Extrusion temperature for the first layer, in degree Celsius,
                            set 0 to disable
        --bed-temperature   Heated bed temperature in degree Celsius, set 0 to disable (default: 200)
        --first-layer-bed-temperature Heated bed temperature for the first layer, in degree Celsius,
                            set 0 to disable (default: same as --bed-temperature)
        
      Speed options:
        --travel-speed      Speed of non-print moves in mm/s
        --perimeter-speed   Speed of print moves for perimeters in mm/s
        --small-perimeter-speed
                            Speed of print moves for small perimeters in mm/s
        --infill-speed      Speed of print moves in mm/s
        --solid-infill-speed Speed of print moves for solid surfaces in mm/s
        --bridge-speed      Speed of bridge print moves in mm/s
        --bottom-layer-speed Speed of print moves for bottom layer, expressed either as an absolute
                            value or as a percentage over normal speeds
        
      Accuracy options:
        --layer-height      Layer height in mm
        --first-layer-height Layer height for first layer (mm or %)
        --infill-every-layers
                            Infill every N layers (default: 1)
      
      Print options:
        --perimeters        Number of perimeters/horizontal skins
        --solid-layers      Number of solid layers to do for top/bottom surfaces
                            (range: 1+, default: 3)
        --fill-density      Infill density (range: 0-1)
        --fill-angle        Infill angle in degrees (range: 0-90, default: 45)
        --fill-pattern      Pattern to use to fill non-solid layers (default: rectilinear)
        --solid-fill-pattern Pattern to use to fill solid layers (default: rectilinear)
        --start-gcode       Load initial gcode from the supplied file. This will overwrite
                            the default command (home all axes [G28]).
        --end-gcode         Load final gcode from the supplied file. This will overwrite 
                            the default commands (turn off temperature [M104 S0],
                            home X axis [G28 X], disable motors [M84]).
        --layer-gcode       Load layer-change G-code from the supplied file (default: nothing).
        --support-material  Generate support material for overhangs
      
       Retraction options:
        --retract-length    Length of retraction in mm when pausing extrusion 
                            (default: 1)
        --retract-restart-extra
                            Additional amount of filament in mm to push after
                            compensating retraction (default: 0)
        --retract-before-travel
                            Only retract before travel moves of this length in mm (default: 2)
        --retract-lift      Lift Z by the given distance in mm when retracting (default: 0)
       
       Cooling options:
        --cooling           Enable fan and cooling control
        --min-fan-speed     Minimum fan speed
        --max-fan-speed     Maximum fan speed
        --bridge-fan-speed  Fan speed to use when bridging
        --fan-below-layer-time Enable fan if layer print time is below this approximate number 
                            of seconds
        --slowdown-below-layer-time Slow down if layer print time is below this approximate number
                            of seconds
        --min-print-speed   Minimum print speed speed
        --disable-fan-first-layers Disable fan for the first N layers
        --fan-always-on     Keep fan always on at min fan speed, even for layers that don't need
                            cooling
       
       Skirt options:
        --skirts            Number of skirts to draw
        --skirt-distance    Distance in mm between innermost skirt and object
        --skirt-height      Height of skirts to draw (expressed in layers, 0+, default: 1)
       
       Transform options:
        --scale             Factor for scaling input object (default: 1)
        --rotate            Rotation angle in degrees (0-360, default: 0)
        --duplicate         Number of items with auto-arrange (1+, default: 1)
        --bed-size          Bed size, only used for auto-arrange
        --duplicate-grid    Number of items with grid arrangement (default: 1,1)
        --duplicate-distance Distance in mm between copies
        
       Miscellaneous options:
        --notes             Notes to be added as comments to the output file
      
       Flow options (advanced):
        --extrusion-width   Set extrusion width manually; it accepts either an absolute value in mm 
		(like 0.65) or a percentage over layer height (like 200%)
        --bridge-flow-ratio Multiplier for extrusion when bridging (> 0, default: 1)
        


If you want to change a preset file, just do

    slic3T.pl --load config.ini --layer-height 0.25 --save config.ini

If you want to slice a file overriding an option contained in your preset file:

    slic3T.pl --load config.ini --layer-height 0.25 file.stl

## How can I integrate Slic3T with Pronterface?

Put this into *slicecommand*:

    slic3T.pl $s --load config.ini --output $o

And this into *sliceoptscommand*:

    slic3T.pl --load config.ini --ignore-nonexistent-config

Replace `slic3T.pl` with the full path to the Slic3T executable and `config.ini`
with the full path of your config file (put it in your home directory or where
you like).
On Mac, the executable has a path like this:

    /Applications/Slic3T.app/Contents/MacOS/Slic3T

## How can I specify a custom filename format for output G-code files?

You can specify a filename format by using any of the config options. 
Just enclose them in square brackets, and Slic3T will replace them upon
exporting.
The additional `[input_filename]` and `[input_filename_base]` options will
be replaced by the input file name (in the second case, the .stl extension 
is stripped).

The default format is `[input_filename_base].gcode`, meaning that if you slice
a *foo.stl* file, the output will be saved to *foo.gcode*.

See below for more complex examples:

    [input_filename_base]_h[layer_height]_p[perimeters]_s[solid_layers].gcode
    [input_filename]_center[print_center]_[layer_height]layers.gcode

