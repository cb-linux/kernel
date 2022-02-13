#!/bin/bash

cd .. && git submodule foreach git pull origin main && git add . && git commit -m "Update submodules"; git push origin main