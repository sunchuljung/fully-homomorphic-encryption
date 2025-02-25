// Copyright 2021 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "ac_int_ops.h"

#pragma hls_top
XlsInt<22, false> isqrt(XlsInt<22, false> num) {
  XlsInt<22, false> res = 0;
  XlsInt<22, false> bit = 1 << 20;  // ((unsigned) INT22_MAX + 1) / 2.

#pragma hls_unroll yes
  for (int i = 0; i < 11; ++i) {
    if (num >= res + bit) {
      num -= res + bit;
      res = (res >> 1) + bit;
    } else {
      res >>= 1;
    }
    bit >>= 2;
  }
  return res;
}
