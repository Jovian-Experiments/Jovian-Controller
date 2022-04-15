Jovian Controller
=================

This project aims to create a simple service that translates the steam deck
controller inputs into usable outputs without the involvement of Steam.

The initial implementation is simplistic, and does not allow for customization.

* * *

Bugs
----

Only one I know of is that the controller will not go back in "lizard mode"
when asked to with the steam controller commands. Even looking at the dumps
from Steam seems to imply it should work.

It's not necessary for me at this point. I would prefer implementing profiles
and allow customizing the input rather than fix this, as the "lizard mode" is
too limited for serious use.
