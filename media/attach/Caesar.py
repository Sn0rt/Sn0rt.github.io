#!/usr/bin/python3
'''
This script for Caesar brute decryption.
'''
__author__ = "Sn0rt@abc.shop.edu.cn"
import string

MAX_KEY_SZIE = 26

def get_message():
    print('enter you message: ')
    return input().lower()

def brute(message):
    for key in range(1, MAX_KEY_SZIE + 1):
        print("%s" % decryption(key, message))

def decryption(key, message):
    key = 0 - key
    transled = ''
    for symbol in message:
        if symbol.isalpha():
            num = ord(symbol)
            num += key
            if num > ord('z'):
                num -= 26
            elif num < ord('a'):
                num += 26
            transled += chr(num)
        else:
            transled += symbol
    return transled

brute(get_message())
