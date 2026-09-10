#!/usr/bin/env python3
# Software License Agreement (BSD License)
#
# Copyright (c) 2022, UFACTORY, Inc.
# All rights reserved.
#
# Author: Vinman <vinman.wen@ufactory.cc> <vinman.cub@gmail.com>

"""
# Notice
#   1. Changes to this file on Studio will not be preserved
#   2. The next conversion will overwrite the file with the same name
# 
# xArm-Python-SDK: https://github.com/xArm-Developer/xArm-Python-SDK
#   1. git clone git@github.com:xArm-Developer/xArm-Python-SDK.git
#   2. cd xArm-Python-SDK
#   3. python setup.py install
"""
import sys
import math
import time
import queue
import datetime
import random
import traceback
import threading
from xarm import version
from xarm.wrapper import XArmAPI


class RobotMain(object):
    """Robot Main Class"""
    def __init__(self, robot, **kwargs):
        self.alive = True
        self._arm = robot
        self._tcp_speed = 100
        self._tcp_acc = 2000
        self._angle_speed = 20
        self._angle_acc = 500
        self._vars = {}
        self._funcs = {}
        self._robot_init()

    # Robot init
    def _robot_init(self):
        self._arm.clean_warn()
        self._arm.clean_error()
        self._arm.motion_enable(True)
        self._arm.set_mode(0)
        self._arm.set_state(0)
        time.sleep(1)
        self._arm.register_error_warn_changed_callback(self._error_warn_changed_callback)
        self._arm.register_state_changed_callback(self._state_changed_callback)
        if hasattr(self._arm, 'register_count_changed_callback'):
            self._arm.register_count_changed_callback(self._count_changed_callback)

    # Register error/warn changed callback
    def _error_warn_changed_callback(self, data):
        if data and data['error_code'] != 0:
            self.alive = False
            self.pprint('err={}, quit'.format(data['error_code']))
            self._arm.release_error_warn_changed_callback(self._error_warn_changed_callback)

    # Register state changed callback
    def _state_changed_callback(self, data):
        if data and data['state'] == 4:
            self.alive = False
            self.pprint('state=4, quit')
            self._arm.release_state_changed_callback(self._state_changed_callback)

    # Register count changed callback
    def _count_changed_callback(self, data):
        if self.is_alive:
            self.pprint('counter val: {}'.format(data['count']))

    def _check_code(self, code, label):
        if not self.is_alive or code != 0:
            self.alive = False
            ret1 = self._arm.get_state()
            ret2 = self._arm.get_err_warn_code()
            self.pprint('{}, code={}, connected={}, state={}, error={}, ret1={}. ret2={}'.format(label, code, self._arm.connected, self._arm.state, self._arm.error_code, ret1, ret2))
        return self.is_alive

    @staticmethod
    def pprint(*args, **kwargs):
        try:
            stack_tuple = traceback.extract_stack(limit=2)[0]
            print('[{}][{}] {}'.format(time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(time.time())), stack_tuple[1], ' '.join(map(str, args))))
        except:
            print(*args, **kwargs)

    @property
    def arm(self):
        return self._arm

    @property
    def VARS(self):
        return self._vars

    @property
    def FUNCS(self):
        return self._funcs

    @property
    def is_alive(self):
        if self.alive and self._arm.connected and self._arm.error_code == 0:
            if self._arm.state == 5:
                cnt = 0
                while self._arm.state == 5 and cnt < 5:
                    cnt += 1
                    time.sleep(0.1)
            return self._arm.state < 4
        else:
            return False

    # Robot Main Run
    def run(self):
        try:
            code = self._arm.set_tcp_load(1.46, [23.84, 15.44, 26.31])
            if not self._check_code(code, 'set_tcp_load'):
                return
            code = self._arm.set_tcp_offset([0, 0, 120, 0, 0, 0], wait=True)
            self._arm.set_state(0)
            if not self._check_code(code, 'set_tcp_offset'):
                return
            time.sleep(0.5)
            self._angle_speed = 180
            self._angle_acc = 800
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 0")
                self._angle_speed = 30
                self._arm.move_gohome()
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 1")
                self._angle_speed = 120
                self._tcp_speed = 500
                self._angle_acc = 500
                code = self._arm.set_servo_angle(angle=[-90.0, -0.4, -183.7, -16.5, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-90.0, -99.9, -164.7, 84.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=60.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 55
                self._tcp_speed = 150
                code = self._arm.set_servo_angle(angle=[-90.0, -0.4, -183.7, -16.5, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 2")
                self._angle_speed = 180
                self._tcp_speed = 1000
                self._angle_acc = 1146
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_position(*[0.0, 660.3, 290.8, 180.0, 0.0, 180.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=60.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 80
                self._tcp_speed = 200
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 3")
                self._angle_speed = 125
                self._tcp_speed = 600
                self._angle_acc = 600
                code = self._arm.set_servo_angle(angle=[-87.1, 65.8, -136.0, 70.2, -203.8], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[91.7, 65.8, -136.0, 72.2, 25.4], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-87.1, 65.8, -136.0, 70.2, -203.8], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 4")
                self._angle_speed = 170
                self._tcp_speed = 950
                self._angle_acc = 1000
                code = self._arm.set_servo_angle(angle=[-1.4, 116.6, -134.5, 5.3, -89.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[4.6, -9.5, -135.7, 160.5, -84.9], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=80.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 170
                self._tcp_speed = 950
                self._angle_acc = 500
                code = self._arm.set_servo_angle(angle=[2.9, 41.7, -129.7, 88.1, -85.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=60.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[69.4, 12.6, -113.2, 100.6, 2.9], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=60.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-0.5, 107.2, -119.6, -12.0, -89.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=60.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-90.1, -11.5, -71.7, 83.3, -214.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=60.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-1.4, 116.6, -134.5, 5.3, -89.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 5")
                self._angle_speed = 150
                self._angle_acc = 700
                self._tcp_speed = 600
                self._tcp_acc = 20000
                code = self._arm.set_servo_angle(angle=[0.0, -65.1, -12.7, 77.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=5.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.move_circle([190.3, -89.1, 11.6, 180.0, 0.0, 95.0], [190.3, 127.3, 11.6, 180.0, 0.0, 91.2], float(360) / 360 * 100, speed=self._tcp_speed, mvacc=self._tcp_acc, wait=False)
                if not self._check_code(code, 'move_circle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, -53.6, -50.7, 117.3, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.2, 63.4, -135.8, 72.4, 31.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=80.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[4.5, -22.5, -13.2, 35.6, -85.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=80.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-86.6, 63.4, -135.8, 72.4, -215.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=80.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 86.6, -175.9, 83.9, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=80.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[2.5, 6.7, -119.4, 130.9, -86.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=80.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_acc = 600
                code = self._arm.set_servo_angle(angle=[0.0, 114.2, -132.7, 0.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 50
                code = self._arm.set_servo_angle(angle=[0.0, -65.1, -12.7, 77.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=5.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 6")
                self._angle_speed = 90
                self._angle_acc = 300
                self._tcp_speed = 300
                self._tcp_acc = 5000
                code = self._arm.set_servo_angle(angle=[0.0, -50.3, -97.0, 164.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 50.1, -135.3, 85.1, -89.4], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 117.4, -124.6, -12.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=5.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, -52.3, -20.6, 76.3, -89.4], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=5.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 140
                code = self._arm.set_servo_angle(angle=[75.1, 35.3, -110.6, 75.3, 5.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=5.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-68.8, 35.3, -110.6, 75.3, -189.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=5.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 110
                code = self._arm.set_servo_angle(angle=[0.0, -50.3, -97.0, 164.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 7")
                self._angle_speed = 100
                self._angle_acc = 100
                code = self._arm.set_pause_time(7)
                if not self._check_code(code, 'set_pause_time'):
                    return
                code = self._arm.set_servo_angle(angle=[-90.0, 90.0, -180.0, 90.0, -201.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.0, 90.0, -180.0, 90.0, 19.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-90.0, 90.0, -180.0, 90.0, -201.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 8")
                self._angle_speed = 100
                self._angle_acc = 700
                code = self._arm.set_servo_angle(angle=[-3.0, 11.1, -102.4, 91.3, -193.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.0, 82.5, -161.3, 79.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 30
                code = self._arm.set_servo_angle(angle=[-3.0, 11.1, -102.4, 91.3, -193.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 9")
                self._angle_speed = 180
                self._angle_acc = 400
                code = self._arm.set_servo_angle(angle=[-88.5, 65.9, -137.7, 71.8, -201.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, -86.8, -12.5, 99.3, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_acc = 400
                code = self._arm.set_servo_angle(angle=[0.0, 35.0, -129.6, 103.1, -90.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_acc = 300
                code = self._arm.set_servo_angle(angle=[0.0, -86.8, -12.5, 99.3, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[88.5, 65.9, -137.7, 71.8, 28.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[1.3, 57.7, -137.7, 79.9, -87.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=230.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[-88.5, 65.9, -137.7, 71.8, -201.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 10")
                self._angle_speed = 80
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[-2.6, 32.6, -125.5, 92.9, -192.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[134.1, 82.5, -161.3, 79.2, -24.9], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 50
                code = self._arm.set_servo_angle(angle=[-2.6, 32.6, -125.5, 92.9, -192.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 11")
                self._angle_speed = 100
                self._angle_acc = 300
                for i in range(int(2)):
                    if not self.is_alive:
                        break
                    code = self._arm.set_servo_angle(angle=[-74.5, 58.8, -150.9, 92.1, -187.4], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                    if not self._check_code(code, 'set_servo_angle'):
                        return
                    code = self._arm.set_servo_angle(angle=[-2.1, 116.3, -129.4, -17.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=700.0)
                    if not self._check_code(code, 'set_servo_angle'):
                        return
                    code = self._arm.set_servo_angle(angle=[82.5, 58.8, -150.9, 92.1, 20.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                    if not self._check_code(code, 'set_servo_angle'):
                        return
                    code = self._arm.set_servo_angle(angle=[-2.1, 116.3, -129.4, -17.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=700.0)
                    if not self._check_code(code, 'set_servo_angle'):
                        return
                    code = self._arm.set_servo_angle(angle=[-74.5, 58.8, -150.9, 92.1, -187.4], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                    if not self._check_code(code, 'set_servo_angle'):
                        return
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 12")
                self._angle_speed = 90
                self._angle_acc = 600
                code = self._arm.set_servo_angle(angle=[90.0, 90.0, -180.0, 90.0, 25.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.0, -80.1, -187.6, -90.0, -18.8], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.0, 90.0, -180.0, 90.0, 25.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 13")
                self._angle_speed = 50
                self._angle_acc = 200
                self._angle_speed = 120
                self._angle_acc = 300
                code = self._arm.set_servo_angle(angle=[0.0, -53.5, -2.0, 55.5, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-39.2, -3.4, -38.3, 41.7, -135.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, -18.1, -101.8, 135.9, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[33.4, 26.6, -88.3, 61.7, -43.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 24.1, -102.1, 80.9, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 68.2, -150.1, 81.9, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._tcp_speed = 1000
                self._tcp_acc = 1000
                code = self._arm.set_position(*[205.3, 0.0, 132.1, 180.0, 0.0, 90.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=-1.0, wait=True)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, -53.5, -2.0, 55.5, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 14")
                self._angle_speed = 115
                self._angle_acc = 600
                code = self._arm.set_servo_angle(angle=[90.0, 1.4, -148.3, 166.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.0, 59.0, -127.4, 68.4, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(0.3)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 100
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[180.0, 62.7, -126.2, 63.5, 15.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 62.7, -126.2, 63.5, -199.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.0, 59.0, -127.4, 68.4, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.0, 1.4, -148.3, 166.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 15")
                self._angle_speed = 110
                self._angle_acc = 350
                code = self._arm.set_servo_angle(angle=[-62.8, 55.8, -116.8, 61.0, -178.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-62.8, 55.8, -116.8, 31.0, -178.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=50.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-62.8, 55.8, -116.8, 91.0, -178.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=50.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-62.8, 55.8, -116.8, 61.0, -178.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 55.9, -123.2, 65.9, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, -73.9, -1.7, 80.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 55.9, -123.2, 65.9, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[62.8, 55.8, -116.8, 61.0, 15.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[62.8, 55.8, -116.8, 31.0, 15.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=50.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[62.8, 55.8, -116.8, 91.0, 15.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=50.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[62.8, 55.8, -116.8, 61.0, 15.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 55.9, -123.2, 65.9, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 170
                self._angle_acc = 600
                code = self._arm.set_servo_angle(angle=[0.0, -73.9, -1.7, 80.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 55.9, -123.2, 65.9, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 110
                self._angle_acc = 350
                code = self._arm.set_servo_angle(angle=[-62.8, 55.8, -116.8, 61.0, -178.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 16")
                self._angle_speed = 150
                self._angle_acc = 300
                code = self._arm.set_servo_angle(angle=[-73.5, 52.7, -161.2, 108.5, -187.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[52.8, 75.6, -123.9, 48.3, -12.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=100.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[73.5, 52.7, -161.2, 108.5, 4.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=100.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-52.8, 75.6, -123.9, 48.3, -169.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=100.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-73.5, 52.7, -161.2, 108.5, -187.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 17")
                self._angle_speed = 180
                self._angle_acc = 1146
                code = self._arm.set_servo_angle(angle=[-83.7, -59.4, 6.9, 52.5, -187.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[91.5, -21.5, -10.0, 31.5, 1.4], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-83.7, -59.4, 6.9, 52.5, -187.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(0)
                if not self._check_code(code, 'set_pause_time'):
                    return
                code = self._arm.set_servo_angle(angle=[91.5, -21.5, -10.0, 31.5, 7.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-83.7, -59.4, 6.9, 52.5, -179.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(0)
                if not self._check_code(code, 'set_pause_time'):
                    return
                code = self._arm.set_servo_angle(angle=[91.5, -21.5, -10.0, 31.5, 17.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-83.7, -59.4, 6.9, 52.5, -170.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(0)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 150
                self._angle_acc = 900
                code = self._arm.set_servo_angle(angle=[0.0, 22.2, -88.6, 66.3, -96.8], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=300.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-83.7, -59.4, 6.9, 52.5, -187.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 18")
                self._angle_speed = 100
                self._angle_acc = 300
                code = self._arm.set_servo_angle(angle=[-67.6, 107.3, -175.5, 68.3, -184.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-39.5, 20.0, -71.2, 51.2, -149.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[9.9, 46.4, -127.2, 84.2, -87.4], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[87.8, 71.1, -145.4, 74.3, 24.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 130
                self._angle_acc = 800
                code = self._arm.set_servo_angle(angle=[69.9, 6.5, -63.3, 56.8, -7.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[31.1, -11.6, -36.0, 47.7, -53.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[6.9, 16.1, -78.2, 62.2, -80.4], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[7.3, 66.9, -141.7, 69.1, -79.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-31.9, 96.3, -203.2, 106.9, -134.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 150
                self._angle_acc = 1000
                code = self._arm.set_servo_angle(angle=[-45.6, 56.6, -109.7, 53.1, -152.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 20
                self._angle_acc = 100
                code = self._arm.set_servo_angle(angle=[-67.6, 107.3, -175.5, 68.3, -184.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 19")
                self._angle_speed = 90
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[10.5, 61.6, -131.0, 67.7, -79.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[8.2, -49.3, -13.2, 66.6, -85.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 10
                self._angle_acc = 50
                code = self._arm.set_servo_angle(angle=[8.2, -49.3, -13.2, 66.6, -78.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 90
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[4.0, 57.1, -126.0, 70.0, -81.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=55.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 50
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[7.6, -4.4, -123.4, 145.9, -80.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=55.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 60
                self._angle_acc = 250
                code = self._arm.set_servo_angle(angle=[52.5, -1.5, -59.1, 60.6, -25.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 40
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[26.8, 28.7, -91.1, 65.7, -58.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[14.2, -7.9, -55.7, 68.4, -76.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[11.1, 38.6, -72.2, 31.8, -73.4], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-14.7, 6.8, -22.1, 15.3, -112.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(0.2)
                if not self._check_code(code, 'set_pause_time'):
                    return
                code = self._arm.set_servo_angle(angle=[28.2, 40.5, -96.8, 56.2, -55.9], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[10.5, 61.6, -131.0, 67.7, -79.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-26.8, 68.5, -140.1, 71.6, -133.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[10.5, 61.6, -131.0, 67.7, -79.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 20")
                self._angle_speed = 60
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[-46.4, 101.8, -171.2, 69.3, -153.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-73.7, 68.6, -137.7, 69.0, -182.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 120
                self._angle_acc = 300
                code = self._arm.set_servo_angle(angle=[-42.3, -0.8, -3.2, 4.0, -137.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 80
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[-21.2, -2.5, -46.6, 49.1, -118.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-13.4, 35.0, -85.3, 50.3, -108.8], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 77.8, -145.0, 61.5, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[34.7, 47.6, -114.8, 67.2, -44.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[52.0, 29.6, -78.7, 49.1, -26.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[7.8, 83.3, -154.3, 65.7, -79.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 20
                self._angle_acc = 100
                code = self._arm.set_servo_angle(angle=[-46.4, 101.8, -171.2, 69.3, -153.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 21")
                self._angle_speed = 130
                self._angle_acc = 700
                code = self._arm.set_servo_angle(angle=[-2.7, 35.5, -147.5, 111.9, -196.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.0, 82.5, -161.3, 79.2, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 35
                code = self._arm.set_servo_angle(angle=[-2.7, 35.5, -147.5, 111.9, -196.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 22")
                self._angle_speed = 180
                self._tcp_speed = 1000
                self._angle_acc = 1146
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_position(*[0.0, 660.3, 103.2, 180.0, 0.0, 180.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=-1.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 80
                self._tcp_speed = 200
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 23")
                self._angle_speed = 150
                self._angle_acc = 250
                code = self._arm.set_servo_angle(angle=[-181.0, -13.7, -161.9, -28.0, -83.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-182.4, -97.3, -161.9, 74.5, -77.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(0.4)
                if not self._check_code(code, 'set_pause_time'):
                    return
                code = self._arm.set_servo_angle(angle=[-180.0, -13.7, -161.9, -28.0, -91.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-132.3, -116.0, -173.2, 111.4, -160.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-178.7, -106.8, -34.9, -54.1, -101.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-128.1, -110.4, -181.5, 112.0, -148.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 120
                self._angle_acc = 250
                code = self._arm.set_servo_angle(angle=[-180.9, -82.1, -218.3, 118.8, -78.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 30
                self._angle_acc = 100
                code = self._arm.set_servo_angle(angle=[-181.0, -13.7, -161.9, -28.0, -83.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 24")
                self._angle_speed = 70
                self._angle_acc = 50
                code = self._arm.set_servo_angle(angle=[-90.0, -0.4, -183.7, -19.6, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-90.0, -99.9, -164.7, 80.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=60.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 50
                self._tcp_speed = 100
                code = self._arm.set_servo_angle(angle=[-90.0, -0.4, -183.7, -19.6, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 25")
                self._angle_speed = 100
                self._angle_acc = 50
                self._tcp_speed = 600
                self._tcp_acc = 1200
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_position(*[0.0, 577.3, 290.5, 180.0, 0.0, 180.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=60.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 80
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 26")
                self._angle_speed = 180
                self._angle_acc = 50
                code = self._arm.set_servo_angle(angle=[-3.0, 11.1, -102.4, 91.3, -200.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[150.5, 49.3, -110.4, 61.0, -16.1], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(2)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 60
                code = self._arm.set_servo_angle(angle=[-3.0, 11.1, -102.4, 91.3, -200.6], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 27")
                self._angle_speed = 70
                self._angle_acc = 40
                code = self._arm.set_servo_angle(angle=[-90.0, 0.0, -177.5, -23.4, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-90.0, -93.7, -209.4, 123.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=500.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-174.5, -98.9, -213.5, 133.2, 9.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 70
                self._tcp_speed = 150
                code = self._arm.set_servo_angle(angle=[-90.0, 0.0, -177.5, -23.4, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 28")
                self._angle_speed = 180
                self._angle_acc = 60
                code = self._arm.set_servo_angle(angle=[0.0, -60.4, -43.1, -65.8, 90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[0.0, 73.3, -160.6, -91.7, 90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=400.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[56.8, 115.0, -198.7, -96.0, 19.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-63.2, 115.0, -198.7, -96.0, 165.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 60
                code = self._arm.set_servo_angle(angle=[0.0, -60.4, -43.1, -65.8, 90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 29")
                self._angle_speed = 120
                self._angle_acc = 40
                code = self._arm.set_servo_angle(angle=[-181.0, -13.7, -161.9, -28.0, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-132.3, -116.0, -173.2, 109.2, -151.2], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 100
                self._angle_acc = 50
                code = self._arm.set_servo_angle(angle=[-178.7, -106.8, -34.9, -54.1, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-128.1, -110.4, -181.5, 112.4, -156.3], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                self._angle_speed = 120
                self._angle_acc = 60
                code = self._arm.set_servo_angle(angle=[-180.9, -82.1, -218.3, 118.8, -86.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 30
                self._angle_acc = 100
                code = self._arm.set_servo_angle(angle=[-181.0, -13.7, -161.9, -28.0, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 30")
                self._angle_speed = 70
                self._angle_acc = 50
                code = self._arm.set_servo_angle(angle=[-90.0, -0.4, -183.7, -19.6, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-90.0, -99.9, -164.7, 80.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-146.1, -98.2, -164.7, 83.5, -14.8], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-33.9, -98.2, -164.7, 83.5, -164.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=60.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 50
                self._tcp_speed = 100
                code = self._arm.set_servo_angle(angle=[-90.0, -0.4, -183.7, -19.6, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and not (self._arm.get_cgpio_digital(6)[1]):
                print("PROGRAM 31")
                self._angle_acc = 50
                self._angle_speed = 70
                self._tcp_speed = 400
                self._tcp_acc = 800
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_position(*[0.0, 577.3, 290.5, 180.0, 0.0, 180.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=60.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                self._angle_speed = 30
                self._angle_acc = 50
                code = self._arm.set_servo_angle(angle=[150.5, 11.2, -83.8, 72.7, -15.9], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 80
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 32")
                self._angle_speed = 100
                self._angle_acc = 700
                code = self._arm.set_servo_angle(angle=[-2.2, 60.6, -137.7, 77.1, -201.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[90.0, 30.1, -142.3, 116.3, -91.7], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                time.sleep(1)
                self._angle_speed = 30
                code = self._arm.set_servo_angle(angle=[-2.2, 60.6, -137.7, 77.1, -201.5], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 33")
                self._angle_speed = 50
                self._angle_acc = 100
                self._tcp_speed = 600
                self._tcp_acc = 600
                code = self._arm.set_servo_angle(angle=[-69.3, 57.9, -128.5, 70.6, -160.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_position(*[245.5, 67.6, 115.5, 180.0, 0.0, 90.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=150.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_position(*[245.0, 582.9, 340.4, 180.0, 0.0, 90.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=-1.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_pause_time(2)
                if not self._check_code(code, 'set_pause_time'):
                    return
                code = self._arm.set_servo_angle(angle=[-69.3, 57.9, -128.5, 70.6, -160.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 34")
                self._angle_speed = 50
                self._angle_acc = 100
                self._tcp_speed = 600
                self._tcp_acc = 600
                code = self._arm.set_servo_angle(angle=[-69.2, 56.4, -142.6, 86.2, -160.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_position(*[244.8, 55.0, 217.5, 180.0, 0.0, 90.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=150.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_position(*[244.8, 644.6, 217.6, 180.0, 0.0, 90.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=-1.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_pause_time(2)
                if not self._check_code(code, 'set_pause_time'):
                    return
                code = self._arm.set_servo_angle(angle=[-69.2, 56.4, -142.6, 86.2, -160.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 35")
                self._angle_speed = 50
                self._angle_acc = 90
                code = self._arm.set_servo_angle(angle=[-69.2, 56.4, -142.6, 86.2, -160.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[69.2, 56.5, -142.7, 86.3, -20.8], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(2)
                if not self._check_code(code, 'set_pause_time'):
                    return
                code = self._arm.set_servo_angle(angle=[-69.2, 56.4, -142.6, 86.2, -160.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=True, radius=-1.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 36")
                self._angle_speed = 60
                self._tcp_speed = 400
                self._angle_acc = 500
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_position(*[0.0, 660.3, 290.8, 180.0, 0.0, 180.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=60.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 55
                self._angle_acc = 200
                code = self._arm.set_servo_angle(angle=[90.0, 16.3, -159.5, 151.0, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 60
                self._tcp_speed = 200
                code = self._arm.set_servo_angle(angle=[90.0, -72.8, -21.9, 94.7, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 37")
                self._angle_speed = 70
                self._angle_acc = 50
                code = self._arm.set_servo_angle(angle=[-90.0, -99.9, -164.7, 80.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_servo_angle(angle=[-90.0, -0.4, -183.7, -19.6, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=60.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_pause_time(1)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 50
                code = self._arm.set_servo_angle(angle=[-90.0, -99.9, -164.7, 80.8, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 38")
                self._angle_speed = 70
                self._tcp_speed = 280
                self._angle_acc = 390
                code = self._arm.set_servo_angle(angle=[90.0, 46.5, -137.6, 91.1, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
                code = self._arm.set_position(*[0.0, 155.0, 290.5, 180.0, 0.0, 180.0], speed=self._tcp_speed, mvacc=self._tcp_acc, radius=60.0, wait=False)
                if not self._check_code(code, 'set_position'):
                    return
                code = self._arm.set_pause_time(2)
                if not self._check_code(code, 'set_pause_time'):
                    return
                self._angle_speed = 70
                self._tcp_speed = 200
                code = self._arm.set_servo_angle(angle=[90.0, 46.5, -137.6, 91.1, -90.0], speed=self._angle_speed, mvacc=self._angle_acc, wait=False, radius=0.0)
                if not self._check_code(code, 'set_servo_angle'):
                    return
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 39")
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 40")
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 41")
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 42")
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 43")
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 44")
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 45")
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 46")
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and not (self._arm.get_cgpio_digital(5)[1]) and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 47")
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 48")
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 49")
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 50")
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 51")
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 52")
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 53")
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 54")
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and not (self._arm.get_cgpio_digital(4)[1]) and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 55")
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 56")
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 57")
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 58")
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and not (self._arm.get_cgpio_digital(3)[1]) and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 59")
            if not (self._arm.get_cgpio_digital(1)[1]) and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 60")
            if self._arm.get_cgpio_digital(1)[1] and not (self._arm.get_cgpio_digital(2)[1]) and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 61")
            if not (self._arm.get_cgpio_digital(1)[1]) and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 62")
            if self._arm.get_cgpio_digital(1)[1] and self._arm.get_cgpio_digital(2)[1] and self._arm.get_cgpio_digital(3)[1] and self._arm.get_cgpio_digital(4)[1] and self._arm.get_cgpio_digital(5)[1] and self._arm.get_cgpio_digital(6)[1]:
                print("PROGRAM 63")
        except Exception as e:
            self.pprint('MainException: {}'.format(e))
        self.alive = False
        self._arm.release_error_warn_changed_callback(self._error_warn_changed_callback)
        self._arm.release_state_changed_callback(self._state_changed_callback)
        if hasattr(self._arm, 'release_count_changed_callback'):
            self._arm.release_count_changed_callback(self._count_changed_callback)


if __name__ == '__main__':
    RobotMain.pprint('xArm-Python-SDK Version:{}'.format(version.__version__))
    arm = XArmAPI('192.168.1.231', baud_checkset=False)
    robot_main = RobotMain(arm)
    robot_main.run()
