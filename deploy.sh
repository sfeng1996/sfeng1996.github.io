#!/bin/bash

git pull

# sfeng 是 algolia s索引
./algolia objects import sfeng -F public/index.json
