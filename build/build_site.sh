#!/bin/bash

# pod2text -80 < ../ASP.pm  > ../README
perl ../asp-perl -b -o ../site ./index.html site 1 ./*.html

rsync --checksum --delete-after --stats --exclude=*.svn* -a --stats ../site/ /usr/local/proj/mlink/site/asp/

