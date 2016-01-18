# sembat
A battery monitoring script for opentx, designed for use with aeroplanes.
Requires OpenTX version 2.1.x

### Features
* Model battery status announced as percentage charge of lowest cell
* Measurements not skewed by current draw from engine
* Announcement frequency increases as the battery drains

### Overview
When a battery has current drawn from it, the voltage across the battery drops. This means the values relayed by battery voltage sensors such as FrSky's VLSS will fall as the throttle is increased, leading to false warnings on the transmitter. This script gets round this problem by only analyzing the cell values when the throttle is below a certain theshhold (by default 10%). This also makes the script easy to invoke: you just reduce the throttle to  below the configured threshold.

#### Inputs
* Cells - You can set the number of cells in your battery via this parameter, and if the transmitter receives a different number, the script will complain via its status code (see below) and issue a low-piched beep. Setting this value to zero (the default) disables cell count checking.

* Thr (%) - This is threshold below which the script is invoked. Note: the scale used is 0 to 100%, not -100% to 100%

#### Outputs
* code - This shows the script's status. The minus symbol blinks approximately once per second to show the script is running. The status codes are as follows:

```
100 -- script working correctly
  0 -- the script didn't load, not recoverable
  1 -- init() did not complete, not recoverable
  2 -- incompatible opentx version, not recoverable 
  3 -- failed to load telemetry ids, recoverable
  4 -- incorrect cell voltages, recoverable 
  5 -- bad cell count, recoverable
```
* vlt - the voltage of the lowest cell, as seen when the script was last invoked.

* pct - the % charge of the lowest cell, as seen when the script was last invoked.

#### Notes
The script will beep once every time the throttle goes below the threshold. A high pich beep means the cell values were read correctly, whereas a low pitch beep means there is either a problem with the script or the battery telemetry. To prevent the script from being annoying, the battery charge is not announced after every check. The blackout period between annoucements varies with the battery charge. Below are the hard-coded values:

```
charge > 75% , max one announcement every 60 seconds
charge > 50%,  max one announcement every 30 seconnd
charge > 40%,  max one announcement every 15 seconds
charge > 30%,  max one announcement every 10 seconds
charge < 30%,  max one announcement every  5 seconds
```

Finally, if there is a change in the status_code, then an annoncement is also made.

Enjoy.




